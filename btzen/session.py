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

import asyncio
import logging
from collections.abc import Coroutine
from contextvars import ContextVar

from .bus import Bus
from .error import BTZenError
from .ndevice import DeviceRegistration

logger = logging.getLogger()

BT_SESSION = ContextVar['Session']('BT_SESSION')

class Session:
    """
    BTZen connection session.

    Await this object to close the session properly.
    """
    def __init__(self, bus: Bus):
        self.bus = bus
        self._is_active = False

        self._device_task: dict[DeviceRegistration, asyncio.Future] = {}
        self._connection_task: dict[str, asyncio.Task] = {}
        self._connection_status: dict[str, asyncio.Event] = {}

        self._event = asyncio.Event()

    def start(self):
        self._is_active = True

    def create_future(self, device: DeviceRegistration, f: Coroutine) -> asyncio.Future:
        assert self._is_active

        task = asyncio.ensure_future(f)
        self._device_task[device] = task
        return task

    def add_connection_task(self, mac: str, f: Coroutine) -> asyncio.Task:
        assert not self._is_active

        self._connection_status[mac] = asyncio.Event()

        task = asyncio.create_task(f)
        task.add_done_callback(self._stop)

        self._connection_task[mac] = task
        return task

    def set_connected(self, mac: str):
        assert self._is_active
        self._connection_status[mac].set()

    def set_disconnected(self, mac: str):
        self._connection_status[mac].clear()

    async def wait_connected(self, mac: str) -> None:
        assert self._is_active

        event = self._connection_status.get(mac)
        if event is None:
            raise BTZenError(
                'Device with address {} not managed by BTZen connection manager'
                .format(mac)
            )
        await event.wait()

    def is_active(self) -> bool:
        return self._is_active

    def cancel_device_tasks(self, mac: str, msg: str):
        tasks = (t for d, t in self._device_task.items() if d.mac == mac)
        for t in tasks:
            t.cancel(msg=msg)

    def stop(self):
        self._is_active = False

        msg = 'BTZen session stopped'
        for t in self._device_task.values():
            t.cancel(msg=msg)
        for t in self._connection_task.values():
            t.cancel(msg=msg)

        logger.info('session is done')

    def _stop(self, task: asyncio.Task):
        """
        Stop BTZen session if task is in error.
        """
        if task.done() and not task.cancelled() and task.exception():
            get_session().stop()
            try:
                task.result()
            except:
                logger.critical('Error in connection task', exc_info=True) 
                self._event.set()

    def __await__(self):
        # just wait forever and stop session on exit
        try:
            yield from self._event.wait().__await__()
        finally:
            self.stop()

def get_session() -> Session:
    return BT_SESSION.get()

# vim: sw=4:et:ai
