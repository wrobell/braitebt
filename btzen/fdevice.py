#
# BTZen - library to asynchronously access Bluetooth devices.
#
# Copyright (C) 2015-2021 by Artur Wroblewski <wrobell@riseup.net>
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.
#

from __future__ import annotations

import asyncio
import logging
import typing as tp
from functools import singledispatch

from . import _btzen  # type: ignore
from .config import DEFAULT_DBUS_TIMEOUT
from .ndevice import DeviceAny, DeviceRegistration, DeviceCharacteristic, \
    DeviceNotifying, DeviceEnvSensing
from .error import CallError
from .session import get_session

logger = logging.getLogger(__name__)

T = tp.TypeVar('T')

async def read(device: DeviceRegistration) -> tp.Any:
    mac = device.mac
    session = get_session()

    if not session.is_active():
        raise CallError('btzen is not running for device {}'.format(device))

    await session.wait_connected(mac)
    if not session.is_active():
        return

    task = session.create_future(device, read_data(device.device, mac))
    return (await task)


@singledispatch
async def read_data(device: DeviceAny, mac: str) -> T:
    pass

@read_data.register
async def _read_env_sensing(device: DeviceCharacteristic, mac: str) -> T:
    bus = get_session().bus
    path = bus.characteristic_path(mac, device.uuid_data)
    assert path is not None

    data = await _btzen.bt_read(bus.system_bus, path, DEFAULT_DBUS_TIMEOUT)
    return device.convert(data)

@read_data.register
async def _read_dev_notifying(device: DeviceNotifying, mac: str) -> T:
    bus = get_session().bus
    dev = device.device
    path = bus.characteristic_path(mac, dev.uuid_data)
    data = await bus._gatt_get(path)
    return dev.convert(data)

@singledispatch
async def enable(device: DeviceAny, mac: str):
    pass

@singledispatch
async def disable(device: DeviceAny, mac: str):
    pass

@enable.register
async def _enable_env_sensing(device: DeviceEnvSensing, mac: str):
    await write_config(mac, device.uuid_conf, device.config_on)

@enable.register
async def _enable_dev_notifying(device: DeviceNotifying, mac: str):
    bus = get_session().bus
    dev = device.device
    await enable(dev, mac)
    path = bus.characteristic_path(mac, dev.uuid_data)
    bus._gatt_start(path)
    logger.info('notifications enabled for {}'.format(path))

@disable.register
async def _disable_env_sensing(device: DeviceEnvSensing, mac: str):
    await disarm_async(
        'device {}/{} disabled'.format(mac, device),
        'cannot disable device {}/{}'.format(mac, device),
        write_config, mac, device.uuid_conf, device.config_off
    )

@disable.register
async def _disable_dev_notifying(device: DeviceNotifying, mac: str):
    bus = get_session().bus
    dev = device.device
    path = bus.characteristic_path(mac, dev.uuid_data)
    assert path is not None
    await disarm(
        'notifications for {}/{} are disabled'.format(mac, device),
        'cannot disable notifications for {}/{}'.format(mac, device),
        bus._gatt_stop, path
    )
    await disable(dev, mac)

async def write_config(mac: str, uuid_conf: str, data: bytes):
    bus = get_session().bus
    path = bus.characteristic_path(mac, uuid_conf)
    await _btzen.bt_write(
        bus.system_bus, path, data, DEFAULT_DBUS_TIMEOUT
    )

# TODO: there is disarm in btzen.cm
async def disarm(msg: str, warn: str, f, *args):
    try:
        f(*args)
        logger.info(msg)
    except (Exception, asyncio.CancelledError) as ex:
        logger.warning(warn + ': ' + str(ex))

async def disarm_async(msg: str, warn: str, f, *args):
    try:
        await f(*args)
        logger.info(msg)
    except (Exception, asyncio.CancelledError) as ex:
        logger.warning(warn + ': ' + str(ex))

# vim: sw=4:et:ai
