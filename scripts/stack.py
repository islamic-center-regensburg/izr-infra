#!/usr/bin/env python3
"""Run isolated Terraform layers and their deployment readiness gates."""

import argparse
import fcntl
import getpass
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
import urllib.parse
import uuid

ROOT = Path(__file__).resolve().parents[1]
STACKS = {
    "projects": "bootstrap/projects",
    "infisical": "bootstrap/infisical/service",
    "infisical-project": "bootstrap/infisical/project",
    "platform-secrets": "bootstrap/secrets",
    "postgres": "bootstrap/postgres",
    "oidc-database": "bootstrap/oidc/database",
    "oidc": "bootstrap/oidc/service",
    "secrets": "projects/{project}/secrets",
    "databases": "projects/{project}/databases",
    "apps": "projects/{project}/apps",
}
GLOBAL = {"projects", "infisical", "infisical-project"}
INFISICAL_CLIENTS = set(STACKS) - {"projects", "infisical"}
ENV_FILE = ROOT / ".env"
TIMEOUT = 300


class DeploymentError(Exception):
    pass


def command(args, env=None, capture=False, input_text=None, accepted=(0,)):
    result = subprocess.run(
        [str(arg) for arg in args], env=env, input=input_text, text=True,
        capture_output=capture, check=False,
    )
    if result.returncode not in accepted:
        detail = (result.stderr or result.stdout).strip() if capture else ""
        raise DeploymentError(f"{args[0]} failed (exit {result.returncode})" + (f": {detail}" if detail else ""))
    return result.stdout if capture else ""


def load_env_file():
    if not ENV_FILE.is_file():
        return
    for line in ENV_FILE.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        if line.startswith("export "):
            line = line[len("export "):]
        key, value = line.split("=", 1)
        key, value = key.strip(), value.strip()
        if len(value) >= 2 and value[0] == value[-1] and value[0] in "'\"":
            value = value[1:-1]
        if not os.environ.get(key):
            os.environ[key] = value


def save_env_value(key, value):
    lines = ENV_FILE.read_text().splitlines() if ENV_FILE.is_file() else []
    lines = [line for line in lines if not re.match(r"\s*(export\s+)?" + re.escape(key) + r"\s*=", line)]
    lines.append(f"{key}={value}")
    descriptor = os.open(ENV_FILE, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(descriptor, "w") as handle:
        handle.write("\n".join(lines) + "\n")
    os.chmod(ENV_FILE, 0o600)
    os.environ[key] = value


def credentials():
    endpoint = os.environ.get("TF_VAR_dokploy_endpoint") or os.environ.get("DOKPLOY_ENDPOINT")
    key = os.environ.get("TF_VAR_dokploy_api_key") or os.environ.get("DOKPLOY_API_KEY")
    if not endpoint or not key:
        raise DeploymentError("Set DOKPLOY_ENDPOINT and DOKPLOY_API_KEY in .env (see .env.example) or export them.")
    return endpoint.rstrip("/"), key


def api(method, route, payload=None):
    endpoint, key = credentials()
    request = urllib.request.Request(
        endpoint + "/api/" + route,
        data=json.dumps(payload).encode() if payload is not None else None,
        headers={"x-api-key": key, "Content-Type": "application/json"},
        method=method,
    )
    try:
        with urllib.request.urlopen(request, timeout=600) as response:
            body = response.read()
    except urllib.error.HTTPError as exc:
        try:
            message = json.loads(exc.read()).get("message", "")
        except (ValueError, AttributeError):
            message = ""
        raise DeploymentError(f"Dokploy {route} returned HTTP {exc.code}" + (f": {message}" if message else "") + ".") from exc
    except urllib.error.URLError as exc:
        raise DeploymentError(f"Dokploy {route} is unreachable: {exc.reason}") from exc
    return json.loads(body) if body else None


def remote(args):
    host = os.environ.get("DOKPLOY_SSH", "")
    if not host or host.startswith("-"):
        raise DeploymentError("Set DOKPLOY_SSH to the SSH host/alias running Dokploy.")
    return command(
        ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10", "--", host, shlex.join(args)],
        capture=True,
    )


def container_state(container):
    ids = remote([
        "docker", "ps", "-aq",
        "--filter", "label=com.docker.compose.project=" + container["project"],
        "--filter", "label=com.docker.compose.service=" + container["service"],
    ]).split()
    if not ids:
        return None
    if len(ids) != 1 or not re.fullmatch(r"[a-f0-9]{12,64}", ids[0]):
        raise DeploymentError(f"Expected one container for {container['project']}/{container['service']}; found {len(ids)}.")
    return json.loads(remote(["docker", "inspect", "--format", "{{json .State}}", ids[0]]))


def wait_containers(containers, previous=None):
    for container in containers:
        deadline = time.monotonic() + TIMEOUT
        key = (container["project"], container["service"])
        while time.monotonic() < deadline:
            state = container_state(container)
            if state is not None:
                status = state["Status"]
                if container["mode"] == "completed":
                    fresh = previous is None or state["StartedAt"] != previous.get(key)
                    if fresh and status == "exited":
                        if state["ExitCode"] != 0:
                            raise DeploymentError(f"Job {key} failed with exit {state['ExitCode']}; inspect its protected logs.")
                        break
                elif state.get("Health", {}).get("Status") == "healthy":
                    break
                if status in ("dead", "removing") or (container["mode"] == "healthy" and status == "exited"):
                    raise DeploymentError(f"Container {key} is {status}.")
            time.sleep(2)
        else:
            raise DeploymentError(f"Timed out waiting for {key} to become {container['mode']}.")
        print(f"Ready: {key[0]}/{key[1]}", flush=True)


def wait_http(check):
    deadline = time.monotonic() + TIMEOUT
    last_error = "no response"
    while time.monotonic() < deadline:
        try:
            with urllib.request.urlopen(check["url"], timeout=15) as response:
                body = response.read()
                if check.get("discovery"):
                    discovery = json.loads(body)
                    if not all(discovery.get(key) for key in ("issuer", "authorization_endpoint", "token_endpoint", "jwks_uri")):
                        raise DeploymentError("OIDC discovery is missing required endpoints.")
                    if discovery["issuer"].rstrip("/") != check["issuer"].rstrip("/"):
                        raise DeploymentError(f"OIDC discovery issuer does not match {check['issuer']}.")
                print(f"Ready: {check['url']}", flush=True)
                return
        except urllib.error.HTTPError as exc:
            if exc.code not in (404, 429, 500, 502, 503, 504):
                raise DeploymentError(f"Readiness check {check['url']} returned HTTP {exc.code}.") from exc
            last_error = f"HTTP {exc.code}"
        except urllib.error.URLError as exc:
            last_error = str(exc.reason)
        except json.JSONDecodeError as exc:
            last_error = f"Invalid discovery JSON: {exc}"
        time.sleep(3)
    raise DeploymentError(f"Timed out waiting for {check['url']}: {last_error}")


def deployment_history(deployment):
    kind = deployment["kind"]
    route = {"application": "deployment.all", "compose": "deployment.allByCompose"}.get(kind)
    if route is None:
        raise DeploymentError(f"Unsupported deployment kind: {kind}")
    return api("GET", route + "?" + urllib.parse.urlencode({kind + "Id": deployment["id"]}))


def application_tasks(name):
    return [
        json.loads(line) for line in remote([
            "docker", "service", "ps", "--no-trunc", "--filter", "desired-state=running",
            "--format", "{{json .}}", name,
        ]).splitlines() if line.strip()
    ]


def request_deployment(deployment):
    # HTTP health and applicationStatus may still describe the previous release.
    kind = deployment["kind"]
    deployment_history(deployment)  # Check read access before queuing any work.
    ticket = dict(deployment, description="izr-stack:" + uuid.uuid4().hex)
    if kind == "application":
        app = api("GET", "application.one?" + urllib.parse.urlencode({"applicationId": deployment["id"]}))
        ticket["app_name"] = app["appName"]
        exists = remote(["docker", "service", "ls", "--format", "{{.Name}}"]).splitlines()
        ticket["previous_tasks"] = {
            task["ID"] for task in application_tasks(app["appName"])
        } if app["appName"] in exists else set()
    api("POST", kind + ".deploy", {
        kind + "Id": deployment["id"], "description": ticket["description"],
    })
    ticket["deadline"] = time.monotonic() + TIMEOUT
    return ticket


def wait_deployment(ticket):
    while time.monotonic() < ticket["deadline"]:
        matches = [
            item for item in deployment_history(ticket)
            if item.get("description") == ticket["description"]
        ]
        if len(matches) > 1:
            raise DeploymentError("Multiple deployments matched this request; inspect protected deployment history.")
        if matches:
            status = matches[0]["status"]
            if status in ("error", "failed", "cancelled", "canceled"):
                raise DeploymentError(f"Deployment {matches[0]['deploymentId']} {status}; inspect its protected logs.")
            if status == "done":
                break
        time.sleep(2)
    else:
        raise DeploymentError(f"Timed out waiting for requested {ticket['kind']} deployment {ticket['id']}.")
    if ticket["kind"] == "application":
        wait_application_rollout(ticket)
    print(f"Deployed: {ticket['kind']}/{ticket['id']}", flush=True)


def wait_application_rollout(ticket):
    name = ticket["app_name"]
    while time.monotonic() < ticket["deadline"]:
        update = json.loads(remote([
            "docker", "service", "inspect", "--format", "{{json .UpdateStatus}}", name,
        ])) or {}
        if update.get("State") in ("paused", "rollback_started", "rollback_paused", "rollback_completed"):
            raise DeploymentError(f"Application {name} rollout {update['State']}; inspect protected service logs.")
        mode = json.loads(remote([
            "docker", "service", "inspect", "--format", "{{json .Spec.Mode}}", name,
        ]))
        replicas = mode.get("Replicated", {}).get("Replicas")
        if not isinstance(replicas, int) or replicas < 1:
            raise DeploymentError(f"Application {name} requires a replicated service with at least one replica.")
        tasks = application_tasks(name)
        if (
            update.get("State") in (None, "completed")
            and len(tasks) == replicas
            and all(task["ID"] not in ticket["previous_tasks"] and task["CurrentState"].startswith("Running ") for task in tasks)
        ):
            return
        time.sleep(2)
    raise DeploymentError(f"Timed out waiting for new application tasks for {name}.")


class Stack:
    def __init__(self, name, environment, project):
        self.name = name
        self.environment = "global" if name in GLOBAL else environment
        self.project = project
        self.relative = STACKS[name].format(project=project)
        self.directory = ROOT / "terraform" / self.relative
        if not self.directory.is_dir():
            raise DeploymentError(f"Missing Terraform root {self.directory}; register and implement the project first.")
        state_root = Path(os.environ.get("STATE_DIR", str(ROOT / ".state"))).resolve()
        self.state = state_root / "states" / self.relative / (self.environment + ".tfstate")
        self.env = os.environ.copy()
        self.env["TF_DATA_DIR"] = str(state_root / "data" / self.relative / self.environment)
        self.cache = Path(self.env.get("TF_PLUGIN_CACHE_DIR", str(state_root / "providers"))).resolve()
        self.cache.mkdir(parents=True, exist_ok=True)
        self.env["TF_PLUGIN_CACHE_DIR"] = str(self.cache)
        for name in ("endpoint", "api_key"):
            value = os.environ.get("TF_VAR_dokploy_" + name) or os.environ.get("DOKPLOY_" + name.upper())
            if value:
                self.env["TF_VAR_dokploy_" + name] = value
        token = os.environ.get("TF_VAR_infisical_token") or os.environ.get("INFISICAL_TOKEN")
        if token:
            self.env["TF_VAR_infisical_token"] = token
        self.tf = os.environ.get("TERRAFORM", "terraform")

    def run(self, args, capture=False, input_text=None, accepted=(0,)):
        return command([self.tf, "-chdir=" + str(self.directory)] + args, env=self.env, capture=capture, input_text=input_text, accepted=accepted)

    def init(self, validation=False):
        self.state.parent.mkdir(parents=True, exist_ok=True)
        args = ["init", "-input=false", "-no-color"]
        if validation:
            self.env["TF_DATA_DIR"] += "-validation"
            args.append("-backend=false")
        else:
            args += ["-reconfigure", "-backend-config=path=" + str(self.state)]
        with (self.cache / ".init.lock").open("a") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            self.run(args, capture=True)

    def outputs(self):
        self.init()
        outputs = json.loads(self.run(["output", "-json"], capture=True))
        if not outputs:
            raise DeploymentError(f"No outputs for {self.name}/{self.environment}; apply that prerequisite first.")
        return {name: output["value"] for name, output in outputs.items() if not output["sensitive"]}

    def dependency(self, name):
        stack = Stack(name, self.environment, self.project)
        outputs = stack.outputs()
        if not stack.state.with_suffix(".deployed").is_file():
            raise DeploymentError(f"{name}/{stack.environment} has not completed deployment successfully; rerun that prerequisite.")
        return outputs

    def inputs(self):
        if self.name == "projects":
            return {}
        topology = self.dependency("projects")["projects"]
        if self.name == "infisical":
            return {"environment_id": topology["secrets"]["environments"]["prod"]}
        if not (os.environ.get("TF_VAR_infisical_token") or os.environ.get("INFISICAL_TOKEN")):
            raise DeploymentError("INFISICAL_TOKEN is not set. Run make infisical-bootstrap once; it stores the token in .env.")
        values = {"infisical_url": self.dependency("infisical")["url"]}
        if self.name == "infisical-project":
            return values
        stage = self.environment
        values.update(environment=stage, infisical_project_id=self.dependency("infisical-project")["project_id"])
        if self.name == "platform-secrets":
            return values
        self.dependency("platform-secrets")
        if self.name == "secrets":
            values["project"] = self.project
            return values
        project = "postgres" if self.name in ("postgres", "oidc-database", "databases") else "oidc" if self.name == "oidc" else self.project
        if project not in topology:
            raise DeploymentError(f"{project} is not registered in bootstrap/projects.")
        values["environment_id"] = topology[project]["environments"][stage]
        if self.name == "postgres":
            return values
        values["postgres_host"] = self.dependency("postgres")["host"]
        if self.name == "oidc":
            self.dependency("oidc-database")
        if self.name in ("databases", "apps"):
            self.dependency("secrets")
            values["project"] = self.project
        if self.name == "apps":
            self.dependency("databases")
            values["oidc_url"] = self.dependency("oidc")["url"]
        return values

    def execute(self, action):
        marker = self.state.with_suffix(".deployed")
        previously_deployed = marker.is_file()
        self.init()
        values = self.inputs()
        credentials()
        args = ["-input=false", "-no-color", "-lock-timeout=120s"]
        filename = "terraform.tfvars" if self.environment == "global" else self.environment + ".tfvars"
        varfile = self.directory / filename
        if varfile.is_file():
            args.append("-var-file=" + filename)
            if re.search(r"(?m)^\s*dokploy_(?:endpoint|api_key)\s*=", varfile.read_text()):
                raise DeploymentError("Dokploy credentials must come from the shared environment, not per-layer tfvars.")
        elif (self.directory / (filename + ".example")).is_file():
            raise DeploymentError(f"Configure {varfile} from its .example before running {self.name}.")
        for name, value in values.items():
            args.append("-var=" + name + "=" + (value if isinstance(value, str) else json.dumps(value)))
        print(f"{action}: {self.relative} [{self.environment}]", flush=True)
        changed = True
        if action in ("apply", "destroy"):
            extra = shlex.split(os.environ.get("TF_APPLY_ARGS", ""))
            if any(arg.startswith("-target") for arg in extra):
                raise DeploymentError("Targeted applies are not supported by the layered workflow.")
            if action == "destroy":
                guard_destroy(self)
            with tempfile.TemporaryDirectory(prefix="izr-plan-") as directory:
                plan = str(Path(directory) / "apply.tfplan")
                mode = ["-destroy"] if action == "destroy" else []
                self.run(["plan"] + mode + args + ["-out=" + plan, "-detailed-exitcode"], accepted=(0, 2))
                description = json.loads(self.run(["show", "-json", plan], capture=True))
                changed = any(
                    resource["mode"] == "managed" and resource["change"]["actions"] != ["no-op"]
                    for resource in description.get("resource_changes", [])
                )
                if changed and "-auto-approve" not in extra:
                    if input(f"Type yes to {action} {self.relative} [{self.environment}]: ").strip() != "yes":
                        raise DeploymentError("Apply cancelled; no apply command was sent.")
                if marker.is_file():
                    marker.unlink()
                self.run(["apply", "-input=false", "-no-color", "-lock-timeout=120s"] + extra + [plan])
        else:
            self.run([action] + args)
        if action != "apply":
            return
        outputs = self.outputs()
        deploy = changed or not previously_deployed or self.name not in ("infisical", "postgres")
        containers = outputs.get("containers", [])
        previous = {}
        for container in containers:
            if deploy and container["mode"] == "completed":
                state = container_state(container)
                previous[(container["project"], container["service"])] = state["StartedAt"] if state else None
        if deploy:
            tickets = [request_deployment(deployment) for deployment in outputs.get("deployments", [])]
            for ticket in tickets:
                wait_deployment(ticket)
        wait_containers(containers, previous if deploy else None)
        for check in outputs.get("checks", []):
            wait_http(check)
        marker.touch()


def guard_destroy(stack):
    downstream = {
        "projects": ["bootstrap/infisical", "bootstrap/secrets", "bootstrap/postgres", "bootstrap/oidc", "projects"],
        "infisical": ["bootstrap/infisical/project", "bootstrap/secrets", "bootstrap/postgres", "bootstrap/oidc", "projects"],
        "infisical-project": ["bootstrap/secrets", "bootstrap/postgres", "bootstrap/oidc", "projects"],
        "platform-secrets": ["bootstrap/postgres", "bootstrap/oidc", "projects"],
        "postgres": ["bootstrap/oidc", "projects"],
        "oidc-database": ["bootstrap/oidc/service", "projects"],
        "oidc": ["projects"],
        "secrets": [f"projects/{stack.project}/databases", f"projects/{stack.project}/apps"],
        "databases": [f"projects/{stack.project}/apps"],
        "apps": [],
    }
    state_root = Path(os.environ.get("STATE_DIR", str(ROOT / ".state"))).resolve() / "states"
    for prefix in downstream[stack.name]:
        for path in (state_root / prefix).rglob("*.tfstate"):
            if stack.environment != "global" and path.stem != stack.environment:
                continue
            if json.loads(path.read_text()).get("resources"):
                raise DeploymentError(f"Destroy downstream resources first: {path}. Shared storage and database contents are retained.")


def preflight():
    for executable in (os.environ.get("TERRAFORM", "terraform"), "ssh"):
        if shutil.which(executable) is None:
            raise DeploymentError(f"Required executable is missing: {executable}")
    credentials()
    version = remote(["docker", "compose", "version", "--short"]).strip()
    match = re.search(r"(\d+)\.(\d+)\.(\d+)", version)
    if not match or tuple(map(int, match.groups())) < (2, 23, 1):
        raise DeploymentError(f"Docker Compose 2.23.1+ is required on the Dokploy host; found {version!r}.")
    print("Preflight passed.", flush=True)


def infisical_bootstrap():
    url = Stack("infisical-project", "dev", "mosque").dependency("infisical")["url"]
    if os.environ.get("INFISICAL_TOKEN"):
        print("INFISICAL_TOKEN is already set; Infisical was bootstrapped. Nothing to do.")
        return
    try:
        with urllib.request.urlopen(url + "/api/v1/admin/config", timeout=30) as response:
            initialized = json.loads(response.read())["config"].get("initialized")
    except (urllib.error.URLError, ValueError, KeyError) as exc:
        raise DeploymentError(f"Could not read Infisical's setup state from {url}: {exc}") from exc
    if initialized:
        raise DeploymentError(
            "Infisical is already bootstrapped, but INFISICAL_TOKEN is not set. Sign in, open Server Console > "
            "Machine Identities > 'Instance Admin Identity', create a token and set INFISICAL_TOKEN in .env."
        )
    print(f"Creating the first Infisical administrator for {url}.")
    print("This works only once per instance. Use these credentials to sign in to the Infisical UI.")
    email = input("Admin email: ").strip()
    organization = input("Organization name [IZR]: ").strip() or "IZR"
    password = getpass.getpass("Admin password (min. 14 characters): ")
    if len(password) < 14:
        raise DeploymentError("Use a password of at least 14 characters.")
    if getpass.getpass("Repeat password: ") != password:
        raise DeploymentError("Passwords do not match; nothing was sent.")
    request = urllib.request.Request(
        url + "/api/v1/admin/bootstrap",
        data=json.dumps({"email": email, "password": password, "organization": organization}).encode(),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(request, timeout=60) as response:
            result = json.loads(response.read())
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode(errors="replace")[:300]
        raise DeploymentError(
            f"Bootstrap returned HTTP {exc.code}: {detail}\nIf the instance is already bootstrapped, sign in, create a token "
            "for 'Instance Admin Identity' (Server Console > Machine Identities) and set INFISICAL_TOKEN in .env."
        ) from exc
    except urllib.error.URLError as exc:
        raise DeploymentError(f"Infisical is unreachable: {exc.reason}") from exc
    save_env_value("INFISICAL_TOKEN", result["identity"]["credentials"]["token"])
    print(f"Bootstrapped organization {result['organization']['name']!r} for {result['user']['email']}.")
    print(f"The non-expiring instance admin token was saved to {ENV_FILE} (mode 600). Keep that file private.")


def infisical_recovery():
    stack = Stack("infisical", "dev", "mosque")
    stack.init()
    keys = json.loads(stack.run(["output", "-json", "recovery"], capture=True))
    print("Store these in a password manager. Without ENCRYPTION_KEY the Infisical database cannot be decrypted.")
    for name, value in keys.items():
        print(f"{name}={value}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("preflight", "init", "validate", "plan", "apply", "destroy", "infisical-bootstrap", "infisical-recovery"))
    parser.add_argument("stack", nargs="?", choices=tuple(STACKS))
    parser.add_argument("--env", choices=("dev", "prod"), default="dev")
    parser.add_argument("--project", default="mosque")
    args = parser.parse_args()
    if not re.fullmatch(r"[a-z][a-z0-9-]{0,31}", args.project):
        parser.error("--project must be a lowercase project slug of at most 32 characters")
    os.umask(0o077)
    load_env_file()
    try:
        if args.action == "preflight":
            preflight()
        elif args.action == "infisical-bootstrap":
            infisical_bootstrap()
        elif args.action == "infisical-recovery":
            infisical_recovery()
        elif args.action in ("init", "validate"):
            for name in ([args.stack] if args.stack else STACKS):
                stack = Stack(name, args.env, args.project)
                stack.init(validation=True)
                if args.action == "validate":
                    stack.run(["validate", "-no-color"])
        else:
            if args.stack is None:
                parser.error("this action requires a stack")
            Stack(args.stack, args.env, args.project).execute(args.action)
    except (DeploymentError, OSError, ValueError, KeyError) as exc:
        print(f"Error: {exc}", file=sys.stderr)
        return 1
    except EOFError:
        print("Input closed; no confirmation was received. Check for partial changes before retrying.", file=sys.stderr)
        return 1
    except KeyboardInterrupt:
        print("\nInterrupted; check for partial changes before retrying.", file=sys.stderr)
        return 130
    return 0


if __name__ == "__main__":
    sys.exit(main())
