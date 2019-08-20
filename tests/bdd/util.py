import socket
import time

from docker.models.containers import Container


def get_port_on_host(container: Container, port_in_container: int):
    return int(
        container.attrs['NetworkSettings']['Ports'][f'{port_in_container}/tcp'][0][
            'HostPort'
        ],
    )


def wait_tcp_port(address, port, timeout=10):
    t = time.monotonic()
    while time.monotonic() - t < timeout:
        try:
            s = socket.create_connection((address, port), timeout=timeout)
            s.close()
            return
        except socket.error:
            time.sleep(0.02)
    raise TimeoutError('Port is closed %s:%i' % (address, port))


def process_defaults(d: dict, defaults2=None):
    if not isinstance(d, dict):
        return d
    defaults2 = defaults2 or {}
    new_d = defaults2.copy()
    defaults1 = d.get("_default", {})
    for k, v in filter(lambda item: item[0] != "_default", d.items()):
        if isinstance(v, dict):
            new_d[k] = process_defaults(v, {**defaults2.get(k, {}), **defaults1})
        else:
            new_d[k] = v
    return new_d
