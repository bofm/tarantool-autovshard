import logging
import subprocess
from dataclasses import dataclass, field
from itertools import count
from pathlib import Path
from string import Template
from textwrap import dedent
from time import sleep
from typing import Dict, Tuple

import pytest
import yaml

# noinspection PyPackageRequirements
from consul import Consul
from docker.errors import APIError
from docker.models.containers import Container
from funcy import (
    compose,
    get_in,
    lcat,
    lfilter,
    lmap,
    log_calls,
    log_durations,
    memoize,
    none_fn,
    partial,
    pluck_attr,
    re_test,
    retry,
)
from pytest_bdd import given, parsers, scenarios, then, when
from requests import RequestException

from bdd.util import get_port_on_host, process_defaults

CONSUL_KV_PREFIX = "autovshard"
CONSUL_CONFIG_KEY = "autovshard_cfg_yaml"

scenarios(Path(__file__).parent / "../features")


@dataclass(frozen=True)
class ConsulBag:
    container: Container

    @property
    def client(self):
        self.container.reload()
        return Consul(port=get_port_on_host(self.container, 8500))


@pytest.fixture
def consul(run_container, run_id):
    """runs Consul in Docker and returns ConsulClient"""
    container = run_container(
        "consul:1.5.3",
        8500,
        command="consul agent -dev -client 0.0.0.0",
        name=f"{run_id}_consul",
        hostname="consul",
    )
    # wait for Consul to start
    bag = ConsulBag(container=container)
    retry(20, RequestException, 0.1)(lambda: bag.client.kv.get("1"))()
    return bag


@dataclass(frozen=True)
class AutovshardReplicaConfig:
    name: str
    uuid: str
    address: str
    master: bool = False
    master_weight: int = 10
    switchover_delay: int = 0


@dataclass(frozen=True)
class AutovshardRSConfig:
    name: str
    uuid: str
    replicas: Dict[str, AutovshardReplicaConfig] = field(default_factory=dict)
    weight: int = 10


@dataclass(frozen=True)
class AutovshardConfig:
    cluster_name: str
    sharding: Dict[str, AutovshardRSConfig]
    rebalancer_max_receiving: int = 10
    bucket_count: int = 100
    rebalancer_disbalance_threshold: int = 10

    def toyaml(self) -> str:
        return yaml.safe_dump(
            {
                "bucket_count": self.bucket_count,
                "rebalancer_disbalance_threshold": self.rebalancer_disbalance_threshold,
                "rebalancer_max_receiving": self.rebalancer_max_receiving,
                "sharding": {
                    rs.uuid: {
                        "weight": rs.weight,
                        "replicas": {
                            replica.uuid: {
                                "name": replica.name,
                                "address": replica.address,
                                "master": replica.master,
                                "master_weight": replica.master_weight,
                                "switchover_delay": replica.switchover_delay,
                            }
                            for replica_name, replica in rs.replicas.items()
                        },
                    }
                    for rs_name, rs in self.sharding.items()
                },
            },
        )


@pytest.fixture(scope="session")
def uuids():
    """
    Monotonically increasing uuids for idempotent tests because Tarantool
    has bugs dependent on the uuid comparison.
    """
    return (f"aaaaaaaa-aaaa-aaaa-aaaa-{f'{i:x}'.zfill(12)}" for i in count())


@pytest.fixture()
def uuid(run_id, uuids):
    uuid_by_param = memoize(lambda *a: next(uuids))
    return partial(uuid_by_param, run_id)


parse_config = compose(process_defaults, yaml.safe_load, dedent)


def parse_autovshard_feature_consul_config(config, run_id, uuid):
    config = parse_config(config)

    return AutovshardConfig(
        cluster_name=f"cluster_{run_id}",
        sharding={
            rs: AutovshardRSConfig(
                name=rs,
                uuid=uuid(rs),
                replicas={
                    replica_name: AutovshardReplicaConfig(
                        name=replica_name,
                        uuid=uuid(replica_name),
                        address=f"{run_id}_{replica_name}:3301",
                        **config[rs][replica_name],
                    )
                    for replica_name in config[rs].keys()
                },
            )
            for rs in config.keys()
        },
    )


def autovshard_consul_config_key(cluster_name):
    return f"{CONSUL_KV_PREFIX}/{cluster_name}/{CONSUL_CONFIG_KEY}"


def write_consul_config(consul_config: str, consul: Consul, run_id: str, uuid):
    """puts autovshard config to Consul"""
    cfg = parse_autovshard_feature_consul_config(consul_config, run_id, uuid)
    consul.kv.put(
        key=autovshard_consul_config_key(cfg.cluster_name), value=cfg.toyaml(),
    )
    return cfg


@given(parsers.parse("autovshard consul config:\n{consul_config}"))
def autovshard_config_in_consul(consul_config: str, consul: ConsulBag, run_id, uuid):
    return write_consul_config(consul_config, consul.client, run_id, uuid)


@then(parsers.parse("autovshard consul config is changed:\n{consul_config}"))
def autovshard_consul_config(consul_config: str, consul: ConsulBag, run_id, uuid):
    return write_consul_config(consul_config, consul.client, run_id, uuid)


def render_template(name, **kwargs):
    template = Template(
        Path(__file__).parent.joinpath("templates").joinpath(name).read_text(),
    )
    return template.substitute(**kwargs)


generate_storage_init = partial(render_template, "init.lua.tpl")


@pytest.fixture(scope="session")
def tarantool_docker_image():
    subprocess.check_call(["make", "-s", "docker"], shell=False)
    image_name = (
        subprocess.check_output(["make", "-s", "docker-image-name"], shell=False)
        .decode()
        .strip()
    )
    assert re_test(r"^\S+$", image_name), f"bad image name: {image_name!r}"
    return image_name


@dataclass(frozen=True)
class DockerTarantoolReplicaset:
    name: str
    replicas: Dict[str, Container]

    @property
    def containers(self):
        return list(self.replicas.values())


@dataclass(frozen=True)
class DockerTarantoolCluster:
    name: str
    replicasets: Dict[str, DockerTarantoolReplicaset]

    @property
    def containers(self):
        return lcat(pluck_attr("containers", self.replicasets.values()))

    def find_container(self, name) -> Container:
        return next(
            container
            for rs in self.replicasets.values()
            for replica_name, container in rs.replicas.items()
            if replica_name == name
        )


@pytest.fixture()
def ok_if_errors_in_logs():
    return set()


def check_tarantool_logs(logs: str):
    lines = logs.splitlines()
    is_ok = [
        # errors that are not actually errors and are OK to occur
        lambda l: "E> ER_LOADING: Instance bootstrap hasn't finished yet" in l,
        lambda l: "E> Cleanup" in l and "reload.lua" in l,
        lambda l: "SystemError unexpected EOF when reading from socket" in l,
        lambda l: "SystemError getaddrinfo: Name does not resolve" in l,
        lambda l: "ER_NO_SUCH_USER: User 'storage' is not found" in l,
        lambda l: "ER_ACCESS_DENIED: Session access to universe '' is denied for user 'storage'"
        in l,
        lambda l: "ER_ACCESS_DENIED: Read access to universe '' is denied for user 'storage'"
        in l,
        lambda l: "Exception during calling 'vshard.storage.buckets_count' on " in l
        and ": Invalid argument" in l,
        lambda l: '"code":77,"message":"Connection refused"' in l,
    ]
    all_errors = lfilter(lambda l: "E>" in l, lines)
    is_real_error = none_fn(*is_ok)
    real_errors = lfilter(is_real_error, all_errors)
    assert not real_errors, "found errors in Tarantool logs"


@given(parsers.parse("Tarantool autovshard cluster:\n{docker_config}"))
def autovshard_docker_cluster(
    docker_config: str,
    autovshard_config_in_consul: AutovshardConfig,
    tmp_path: Path,
    create_container,
    run_id,
    tarantool_docker_image,
    ok_if_errors_in_logs,
) -> DockerTarantoolCluster:
    """deploys tarantool cluster"""
    autovshard_config_in_consul: AutovshardConfig

    cluster = DockerTarantoolCluster(
        name=autovshard_config_in_consul.cluster_name, replicasets={},
    )

    def to_lua_bool_str(b: bool):
        return "true" if b else "false"

    for rs_name, rs in parse_config(docker_config).items():
        for replica_name, replica in rs.items():
            rs = autovshard_config_in_consul.sharding[rs_name]
            tarantool_init_script = generate_storage_init(
                replicaset_uuid=rs.uuid,
                instance_uuid=rs.replicas[replica_name].uuid,
                cluster_name=autovshard_config_in_consul.cluster_name,
                router=to_lua_bool_str(replica["router"]),
                storage=to_lua_bool_str(replica["storage"]),
                automaster=to_lua_bool_str(replica["automaster"]),
                consul_session_ttl=replica.get("consul_session_ttl", "nil"),
                consul_http_address=f"http://{run_id}_consul:8500",
            )
            init_file: Path = tmp_path.joinpath(f"storage_{replica_name}.lua")
            init_file.write_text(tarantool_init_script)
            c = create_container(
                tarantool_docker_image,
                None,
                command=["tarantool", f"/{init_file.name}"],
                entrypoint="",
                name=f"{run_id}_{replica_name}",
                hostname=replica_name,
                volumes={
                    str(init_file.resolve()): {
                        "bind": f"/{init_file.name}",
                        "mode": "ro",
                    },
                },
            )
            cluster.replicasets.setdefault(
                rs_name, DockerTarantoolReplicaset(name=rs_name, replicas={}),
            ).replicas[replica_name] = c

    yield cluster

    for rs in cluster.replicasets.values():
        for name, container in rs.replicas.items():
            container.reload()
            logs = container.logs().decode()
            print(f"================= {container.name} logs ======================")
            print(logs)
            if container not in ok_if_errors_in_logs:
                check_tarantool_logs(logs)


def start_container(c: Container):
    c.reload()
    c.start()
    c.reload()
    return c


@when(parsers.parse("all instances in {rs} are started"))
def start_rs_containers(rs, autovshard_docker_cluster):
    return lmap(start_container, autovshard_docker_cluster.containers)


@when(parsers.parse("{t} is started"))
@then(parsers.parse("{t} is started"))
@log_calls(logging.debug)
def start_container_by_name(t, autovshard_docker_cluster):
    c = autovshard_docker_cluster.find_container(t)
    start_container(c)


@then(parsers.parse("{replica_name} autovshard consul config role should be {role}"))
def check_t_consul_config_role(
    replica_name, role, consul, autovshard_config_in_consul, uuid,
):
    key = autovshard_consul_config_key(autovshard_config_in_consul.cluster_name)
    _, kv = consul.kv.get(key)
    assert kv["Value"]
    cfg = yaml.safe_load(kv["Value"])

    def getmaster(rs_uuid):
        return get_in(
            cfg, ["sharding", rs_uuid, "replicas", uuid(replica_name), "master"],
        )

    master = next(map(getmaster, cfg["sharding"].keys()))
    expected_master = role == "master"
    assert master == expected_master, (
        f"unexpected master parameter in " f"consul config for {replica_name}"
    )


@when(parsers.parse("after {seconds:g} seconds have passed"))
@then(parsers.parse("after {seconds:g} seconds have passed"))
def step_sleep(seconds):
    sleep(seconds)


def container_tnt_eval(
    c: Container, lua_script, suppress_errors=False,
) -> Tuple[int, bytes]:
    code, output = c.exec_run(
        ["bash", "-ec", f'cat <<"EOF" | tarantoolctl connect 3301\n{lua_script}\nEOF\n'],
    )
    if not suppress_errors:
        assert (
            code == 0
        ), f"{c.name} exec returned status {code} and output: {output.decode()}"
    return output


def do_check_t_actual_role(t, mode, autovshard_docker_cluster):
    container = autovshard_docker_cluster.find_container(t)
    if mode == "down":
        container.reload()
        assert container.status == "exited", f"unexpected mode for {t}"
        return

    output = container_tnt_eval(
        container,
        "local i=box.info() return i.ro and 'I_AM_' .. 'RO' or 'I_AM_' .. 'RW'",
    )

    actual_mode = "unknown"
    if b"I_AM_RO" in output:
        actual_mode = "RO"
    elif b"I_AM_RW" in output:
        actual_mode = "RW"

    assert actual_mode == mode, f"unexpected mode for {t}"


@when(parsers.parse("{t} should become {mode} in less than {seconds:d} seconds"))
@then(parsers.parse("{t} should become {mode} in less than {seconds:d} seconds"))
@log_durations(logging.debug)
def wait_for_t_role(t, mode, seconds, autovshard_docker_cluster):
    check = retry(seconds, errors=(AssertionError, APIError), timeout=1)(
        do_check_t_actual_role,
    )
    check(t, mode, autovshard_docker_cluster)


@when(parsers.parse("{t} should be {mode}"))
@then(parsers.parse("{t} should be {mode}"))
def check_t_actual_role(t, mode, autovshard_docker_cluster):
    do_check_t_actual_role(t, mode, autovshard_docker_cluster)


@when("vshard router API should work on all instances")
@then("vshard router API should work on all instances")
def check_public_router_api(autovshard_docker_cluster):
    for c in autovshard_docker_cluster.containers:
        check_router_api(c)


@when(parsers.parse("{t} vshard router API should work"))
@then(parsers.parse("{t} vshard router API should work"))
@log_calls(logging.debug)
def check_public_router_api(t, autovshard_docker_cluster):
    c = autovshard_docker_cluster.find_container(t)
    check_router_api(c)


@log_calls(logging.debug)
def check_router_api(c: Container):
    c.reload()
    # fmt: off
    script = dedent('''
        do 
            assert(router.test(1) == "test ok")
            assert(router.test(2) == "test ok")
            assert(router.test(3) == "test ok")
            return "CHECK" .. "OK"
        end
    ''')
    # fmt: on
    output = container_tnt_eval(c, script)
    assert b"CHECKOK" in output


@when(parsers.parse("{t} is crashed"))
@then(parsers.parse("{t} is crashed"))
@log_calls(logging.debug)
def crash_tarantool(t, autovshard_docker_cluster, ok_if_errors_in_logs):
    container = autovshard_docker_cluster.find_container(t)
    container_tnt_eval(container, "require('ffi').cast('char *', 0)[0] = 48", True)
    ok_if_errors_in_logs.add(container)


@when("consul becomes unreachable")
def kill_consul(consul, autovshard_docker_cluster, ok_if_errors_in_logs):
    c = consul.container
    c.kill()
    lmap(ok_if_errors_in_logs.add, autovshard_docker_cluster.containers)
