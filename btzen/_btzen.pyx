#
# BTZen - Bluetooth Smart sensor reading library.
#
# Copyright (C) 2015-2018 by Artur Wroblewski <wrobell@riseup.net>
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

# distutils: language = c
# cython: c_string_type=unicode, c_string_encoding=utf8, language_level=3str

from libc.stdio cimport perror
from libc.string cimport strerror
from libc.errno cimport errno

from cpython.bytes cimport PyBytes_FromStringAndSize

import asyncio
import logging
from contextlib import contextmanager

from .error import *

logger = logging.getLogger(__name__)

FMT_RULE = """
type='signal',
sender='org.bluez',
interface='org.freedesktop.DBus.Properties',
member='PropertiesChanged',
path='{}',
arg0='{}'
"""

cdef extern from "<systemd/sd-bus.h>":
    ctypedef struct sd_bus:
        pass

    ctypedef struct sd_bus_message:
        pass

    ctypedef struct sd_bus_slot:
        pass

    ctypedef struct sd_bus_error:
        const char *name
        const char *message

    ctypedef int (*sd_bus_message_handler_t)(sd_bus_message*, void*, sd_bus_error*)

    int sd_bus_default_system(sd_bus**)
    int sd_bus_get_fd(sd_bus*)
    int sd_bus_process(sd_bus*, sd_bus_message**)

    int sd_bus_call_method(sd_bus*, const char*, const char*, const char*, const char*, sd_bus_error*, sd_bus_message**, const char*, ...)
    int sd_bus_call_method_async(sd_bus*, sd_bus_slot**, const char*, const char*, const char*, const char*, sd_bus_message_handler_t, void*, const char*, ...)
    int sd_bus_message_new_method_call(sd_bus*, sd_bus_message**, const char*, const char*, const char*, const char*)
    int sd_bus_message_append_array(sd_bus_message*, char, const void*, size_t)
    int sd_bus_message_append_basic(sd_bus_message*, char, const void*)
    int sd_bus_message_append(sd_bus_message*, const char*, ...)
    int sd_bus_message_open_container(sd_bus_message*, char, const char*)
    int sd_bus_message_close_container(sd_bus_message*)
    int sd_bus_call(sd_bus*, sd_bus_message*, long, sd_bus_error*, sd_bus_message**)
    int sd_bus_call_async(sd_bus*, sd_bus_slot*, sd_bus_message*, sd_bus_message_handler_t, void*, long)

    int sd_bus_get_property(sd_bus*, const char*, const char*, const char*, const char*, sd_bus_error*, sd_bus_message**, const char*)

    const sd_bus_error *sd_bus_message_get_error(sd_bus_message*)
    const char *sd_bus_message_get_path(sd_bus_message*)
    int sd_bus_message_read(sd_bus_message*, const char*, ...)
    int sd_bus_message_read_basic(sd_bus_message*, char, void*)
    int sd_bus_message_read_array(sd_bus_message*, char, const void**, size_t*)
    int sd_bus_message_enter_container(sd_bus_message*, char, const char*)
    int sd_bus_message_exit_container(sd_bus_message*)
    int sd_bus_message_skip(sd_bus_message*, const char*)
    int sd_bus_message_get_type(sd_bus_message*, unsigned char*)
    int sd_bus_message_peek_type(sd_bus_message*, char*, const char**)

    int sd_bus_add_match(sd_bus*, sd_bus_slot**, const char*, sd_bus_message_handler_t, void*)

    sd_bus *sd_bus_unref(sd_bus*)
    sd_bus_message *sd_bus_message_unref(sd_bus_message*)
    void sd_bus_error_free(sd_bus_error*)
    sd_bus_slot* sd_bus_slot_unref(sd_bus_slot*)

cdef sd_bus_error SD_BUS_ERROR_NULL = sd_bus_error(NULL, NULL, 0)

cdef class Bus:
    cdef sd_bus *bus
    cdef readonly int _fd_no

    @property
    def fileno(self):
        return self._fd_no

cdef class PropertyNotification:
    cdef sd_bus_slot *slot
    cdef public object queues
    cdef public str path

    def __init__(self, path):
        self.queues = {}
        self.path = path

    def register(self, name):
        assert name not in self.queues
        assert self.slot is not NULL
        self.queues[name] = asyncio.Queue()

    def is_registered(self, name):
        return name in self.queues

    def put(self, name, value):
        assert name in self.queues
        assert self.slot is not NULL
        self.queues[name].put_nowait(value)

    async def get(self, name):
        assert name in self.queues
        assert self.slot is not NULL
        return (await self.queues[name].get())

    def size(self, name) -> int:
        return self.queues[name].qsize()

    def stop(self):
        self.queues.clear()
        sd_bus_slot_unref(self.slot)

cdef fmt_rule(iface, path):
    rule = FMT_RULE.format(path, iface)
    rule = rule.strip().replace('\n', '')
    return rule.encode()

def check_call(msg_err, code):
    """
    Raise call error if a D-Bus call has failed.
    """
    if code < 0:
        msg_err = 'Call failed - {}: {} ({})'.format(
            msg_err, strerror(-code), code
        )
        raise CallError(msg_err)

def default_bus():
    cdef Bus bus = Bus.__new__(Bus)
    cdef int r

    r = sd_bus_default_system(&bus.bus)
    check_call('connect bus', r)
    bus._fd_no = sd_bus_get_fd(bus.bus)

    return bus

cdef int task_cb_connect(sd_bus_message *msg, void *user_data, sd_bus_error *ret_error) with gil:
    cdef object task = <object>user_data
    cdef const sd_bus_error *error = sd_bus_message_get_error(msg)

    if error and error.message:
        task.set_exception(ConnectionError(error.message))
    else:
        task.set_result(None)
    return 1

async def bt_connect(Bus bus, str path):
    """
    Connect to Bluetooth device.

    :param bus: D-Bus reference.
    :param path: D-Bus device path.
    """
    assert bus is not None

    task = asyncio.get_event_loop().create_future()
    r = sd_bus_call_method_async(
        bus.bus,
        NULL,
        'org.bluez',
        path.encode(),
        'org.bluez.Device1',
        'Connect',
        task_cb_connect,
        <void*>task,
        NULL,
        NULL
    )
    check_call('connect to {}'.format(path), r)
    await task

async def bt_connect_adapter(Bus bus, str path, str address):
    """
    Connect to Bluetooth device.

    :param bus: D-Bus reference.
    :param path: D-Bus adapter path.
    :param address: Bluetooth device address.
    """
    assert bus is not None

    buff = address.encode()
    cdef sd_bus_message *msg = NULL
    cdef unsigned char *addr_data = buff

    task = asyncio.get_event_loop().create_future()
    try:
        r = sd_bus_message_new_method_call(
            bus.bus,
            &msg,
            'org.bluez',
            path.encode(),
            'org.bluez.Adapter1',
            'ConnectDevice'
        )
        check_call('write data to {}'.format(path), r)

        r = sd_bus_message_append(msg, 'a{sv}', 2, 'Address', 's', addr_data, "AddressType", "s", "public")
        check_call('write data to {}'.format(path), r)

        r = sd_bus_call_async(bus.bus, NULL, msg, task_cb_connect, <void*>task, 0)
        check_call('write data to {}'.format(path), r)

        return (await task)
    finally:
        sd_bus_message_unref(msg)

cdef int task_cb_read(sd_bus_message *msg, void *user_data, sd_bus_error *ret_error) with gil:
    cdef object task = <object>user_data
    cdef const sd_bus_error *error = sd_bus_message_get_error(msg)
    cdef BusMessage bus_msg = BusMessage.__new__(BusMessage)

    if error and error.message:
        task.set_exception(DataReadError(error.message))
    else:
        bus_msg.c_obj = msg
        value = msg_read_value(bus_msg, 'y')
        task.set_result(value)
    return 1

async def bt_read(Bus bus, str path):
    assert bus is not None

    task = asyncio.get_event_loop().create_future()

    r = sd_bus_call_method_async(
        bus.bus,
        NULL,
        'org.bluez',
        path.encode(),
        'org.bluez.GattCharacteristic1',
        'ReadValue',
        task_cb_read,
        <void*>task,
        'a{sv}',
        NULL
    )
    check_call('read data from {}'.format(path), r)

    return (await task)

cdef int task_cb_write(sd_bus_message *msg, void *user_data, sd_bus_error *ret_error) with gil:
    """
    Data write callback used by `bt_write` function.
    """
    cdef object task = <object>user_data
    cdef const sd_bus_error *error = sd_bus_message_get_error(msg)
    if error and error.message:
        task.set_exception(DataWriteError(error.message))
    else:
        task.set_result(None)
    return 1

async def bt_write(Bus bus, str path, bytes data):
    """
    Write data to Bluetooth device.

    :param bus: D-Bus reference.
    :param path: GATT characteristics path of the device.
    :param data: Data to write.
    """
    assert bus is not None

    cdef sd_bus_message *msg = NULL
    cdef char* buff = data

    task = asyncio.get_event_loop().create_future()
    try:
        r = sd_bus_message_new_method_call(
            bus.bus,
            &msg,
            'org.bluez',
            path.encode(),
            'org.bluez.GattCharacteristic1',
            'WriteValue'
        )
        check_call('write data to {}'.format(path), r)

        r = sd_bus_message_append_array(msg, 'y', buff, len(data))
        check_call('write data to {}'.format(path), r)

        r = sd_bus_message_open_container(msg, 'a', '{sv}')
        check_call('write data to {}'.format(path), r)

        r = sd_bus_message_close_container(msg)
        check_call('write data to {}'.format(path), r)

        r = sd_bus_call_async(bus.bus, NULL, msg, task_cb_write, <void*>task, 0)
        check_call('write data to {}'.format(path), r)

        return (await task)
    finally:
        sd_bus_message_unref(msg)

def bt_write_sync(Bus bus, str path, bytes data):
    """
    Write data to Bluetooth device.

    :param bus: D-Bus reference.
    :param path: GATT characteristics path of the device.
    :param data: Data to write.
    """
    assert bus is not None

    cdef sd_bus_message *msg = NULL
    cdef sd_bus_message *ret_msg = NULL
    cdef sd_bus_error error = SD_BUS_ERROR_NULL
    cdef char* buff = data

    r = sd_bus_message_new_method_call(
        bus.bus,
        &msg,
        'org.bluez',
        path.encode(),
        'org.bluez.GattCharacteristic1',
        'WriteValue'
    )
    check_call('write data to {}'.format(path), r)

    r = sd_bus_message_append_array(msg, 'y', buff, len(data))
    check_call('write data to {}'.format(path), r)

    r = sd_bus_message_open_container(msg, 'a', '{sv}')
    check_call('write data to {}'.format(path), r)

    r = sd_bus_message_close_container(msg)
    check_call('write data to {}'.format(path), r)

    r = sd_bus_call(bus.bus, msg, 0, &error, &ret_msg)
    check_call('write data to {}'.format(path), r)

cdef int task_cb_property_monitor(sd_bus_message *msg, void *user_data, sd_bus_error *ret_error) with gil:
    cdef object cb = <object>user_data
    cdef char msg_type
    cdef const char *path
    cdef BusMessage bus_msg = BusMessage.__new__(BusMessage)

    path = sd_bus_message_get_path(msg)
    assert path == cb.path
    bus_msg.c_obj = msg

    # skip interface name
    msg_skip(bus_msg, 's')

    for _ in msg_container_dict(bus_msg, '{sv}'):
        name = msg_read_value(bus_msg, 's')
        if cb.is_registered(name):
            value = msg_read_value(bus_msg, 'v')
            cb.put(name, value)
        else:
            msg_skip(bus_msg, 'v')

    return 0

def bt_property_monitor_start(Bus bus, str path, str iface):
    """
    Enable notification of value changes of Bluetooth device property.

    Property notification object is returned, which allows to register
    property names.

    :param bus: D-Bus reference.
    :param path: GATT characteristics path of the device.
    :param iface: Device interface.
    """
    assert bus is not None

    cdef sd_bus_slot *slot

    rule = fmt_rule(iface, path)
    data = PropertyNotification(path)

    r = sd_bus_add_match(
        bus.bus,
        &slot,
        rule,
        task_cb_property_monitor,
        <void*>data
    )
    check_call('bus match rule', r)
    assert slot is not NULL

    data.slot = slot
    return data

def bt_property_str(Bus bus, str path, str iface, str name):
    assert bus is not None

    cdef sd_bus_message *msg = NULL
    cdef sd_bus_error error = SD_BUS_ERROR_NULL
    cdef BusMessage bus_msg = BusMessage.__new__(BusMessage)

    r = sd_bus_get_property(
        bus.bus,
        'org.bluez',
        path.encode(),
        iface.encode(),
        name.encode(),
        &error,
        &msg,
        's'
    )
    assert r == 0, strerror(-r)

    bus_msg.c_obj = msg
    value = msg_read_value(bus_msg, 's')
    sd_bus_message_unref(msg)
    sd_bus_error_free(&error)

    return value

def bt_property_bool(Bus bus, str path, str iface, str name):
    assert bus is not None

    cdef sd_bus_message *msg = NULL
    cdef sd_bus_error error = SD_BUS_ERROR_NULL
    cdef BusMessage bus_msg = BusMessage.__new__(BusMessage)

    r = sd_bus_get_property(
        bus.bus,
        'org.bluez',
        path.encode(),
        iface.encode(),
        name.encode(),
        &error,
        &msg,
        'b'
    )
    if r != 0:
        raise DataReadError(strerror(-r))

    bus_msg.c_obj = msg
    value = msg_read_value(bus_msg, 'b')
    sd_bus_message_unref(msg)
    sd_bus_error_free(&error)

    return value

def bt_notify_start(Bus bus, str path):
    """
    Start monitoring value changes of a device identified by GATT
    characteristics path.

    :param bus: D-Bus reference.
    :param path: GATT characteristics path of the device.
    """
    assert bus is not None

    cdef sd_bus_message *msg = NULL
    cdef sd_bus_error error = SD_BUS_ERROR_NULL

    iface = 'org.bluez.GattCharacteristic1'

    r = sd_bus_call_method(
        bus.bus,
        'org.bluez',
        path.encode(),
        iface.encode(),
        'StartNotify',
        &error,
        &msg,
        NULL,
        NULL
    )
    check_call('start notification', r)

def bt_notify_stop(Bus bus, str path):
    """
    Stop monitoring value changes of a device identified by GATT
    characteristics path.

    :param bus: D-Bus reference.
    :param path: GATT characteristics path of the device.
    """
    assert bus is not None

    cdef sd_bus_message *msg = NULL
    cdef sd_bus_error error = SD_BUS_ERROR_NULL

    try:
        r = sd_bus_call_method(
            bus.bus,
            'org.bluez',
            path.encode(),
            'org.bluez.GattCharacteristic1',
            'StopNotify',
            &error,
            &msg,
            NULL,
            NULL
        )
        check_call('stop notification', r)
    finally:
        sd_bus_error_free(&error)
        sd_bus_message_unref(msg)

def bt_process(Bus bus):
    """
    Process D-Bus events.
    """
    cdef int r
    assert bus is not None

    r = sd_bus_process(bus.bus, NULL)
    while r > 0:
        r = sd_bus_process(bus.bus, NULL)

def bt_characteristic(Bus bus, str path):
    """
    Fetch Gatt Characteristic paths relative to `path`.

    Dictionary `uuid -> path` is returned.
    """
    assert bus is not None

    cdef sd_bus_message *msg = NULL
    cdef sd_bus_error error = SD_BUS_ERROR_NULL
    cdef BusMessage bus_msg = BusMessage.__new__(BusMessage)

    try:
        r = sd_bus_call_method(
            bus.bus,
            'org.bluez',
            '/',
            'org.freedesktop.DBus.ObjectManager',
            'GetManagedObjects',
            &error,
            &msg,
            NULL
        )
        if r < 0:
            raise ConfigurationError(
                'Failed to get GATT characteristics paths: {}'
                .format(strerror(-r))
            )

        bus_msg.c_obj = msg

        data = _parse_characteristics(bus_msg, path)

    finally:
        sd_bus_message_unref(msg)
        sd_bus_error_free(&error)

    return data

def _parse_characteristics(BusMessage bus_msg, str path):
    data = {}
    for _ in msg_container_dict(bus_msg, '{oa{sa{sv}}}'):
        chr_path = msg_read_value(bus_msg, 'o')

        if not chr_path.startswith(path):
             msg_skip(bus_msg, 'a{sa{sv}}')
             continue

        for _ in msg_container_dict(bus_msg, '{sa{sv}}'):
            iface = msg_read_value(bus_msg, 's')

            if iface != 'org.bluez.GattCharacteristic1':
                msg_skip(bus_msg, 'a{sv}')
                continue

            for _ in msg_container_dict(bus_msg, '{sv}'):
                name = msg_read_value(bus_msg, 's')
                if name == 'UUID':
                    uuid = msg_read_value(bus_msg, 'v')
                    data[uuid] = chr_path
                else:
                    msg_skip(bus_msg, 'v')
    return data

#
# sd-bus message parsing
#
cdef class BusMessage:
    """
    Python level wrapper around SD bus message structure.
    """
    cdef sd_bus_message *c_obj

class BusMessageError(Error):
    """
    Bus message parsing error.
    """

def check_msg_error(r):
    if r < 0:
        raise BusMessageError(
            'D-Bus message parsing error: {}'.format(strerror(-r))
        )

@contextmanager
def msg_container(BusMessage bus_msg, str type, str contents):
    """
    Parse single D-Bus container entry of given type and contents.
    """
    cdef char msg_type = ord(type)
    cdef sd_bus_message *msg = bus_msg.c_obj

    r = sd_bus_message_enter_container(msg, msg_type, contents.encode())
    check_msg_error(r)

    yield

    r = sd_bus_message_exit_container(msg)
    check_msg_error(r)

def msg_container_dict(BusMessage bus_msg, str contents):
    """
    Loop over items of D-Bus message dictionary container.
    """
    with msg_container(bus_msg, 'a', contents):
        for _ in msg_container_loop(bus_msg, 'e', contents[1:-1]):
            yield

def msg_container_loop(BusMessage bus_msg, str type, str contents):
    """
    Loop over items of D-Bus message container.

    For dictionary containers use `msg_container_dict`.
    """
    cdef char msg_type = ord(type)
    cdef sd_bus_message *msg = bus_msg.c_obj

    while True:
        r = sd_bus_message_enter_container(msg, msg_type, contents.encode())
        check_msg_error(r)
        if r == 0:
            break

        yield

        r = sd_bus_message_exit_container(msg)
        check_msg_error(r)

def msg_read_value(BusMessage bus_msg, str type):
    """
    Read a value from a sd-bus message of given type.

    Supported values

    - boolean
    - signed short int
    - string
    - byte array
    - variant
    """
    cdef sd_bus_message *msg = bus_msg.c_obj

    cdef bytes value_str
    cdef int value
    cdef signed short value_short
    cdef const void *buff
    cdef size_t buff_size
    cdef char *buff_str
    cdef const char *contents
    cdef char msg_type_v

    msg_type = type.encode()

    if msg_type == b'b':
        r = sd_bus_message_read_basic(msg, 'b', &value)
        check_msg_error(r)
        r_value = value == 1

    elif msg_type == b'n':
        r = sd_bus_message_read_basic(msg, 'n', &value_short)
        check_msg_error(r)
        r_value = value_short

    elif msg_type == b'ay' or msg_type == b'y':
        r = sd_bus_message_read_array(msg, 'y', &buff, &buff_size)
        check_msg_error(r)

        r_value = PyBytes_FromStringAndSize(<char*>buff, buff_size)
        logger.debug('array value of size: {}'.format(buff_size))

    elif msg_type == b's' or msg_type == b'o':
        r = sd_bus_message_read(msg, msg_type, &buff_str)
        check_msg_error(r)
        r_value = <str>buff_str
        logger.debug('string value: {} of size {}'.format(r_value, len(r_value)))

    elif msg_type == b'v':
        r = sd_bus_message_peek_type(msg, &msg_type_v, &contents)
        check_msg_error(r)
        assert chr(msg_type_v) == 'v', (msg_type, contents)

        with msg_container(bus_msg, type, contents):
            r_value = msg_read_value(bus_msg, contents)
    else:
        # FIXME: add support for other types
        raise BusMessageError('Unknown message type: {}'.format(type))

    return r_value

cdef void msg_skip(BusMessage bus_msg, str type) except *:
    """
    Skip D-Bus message entry of given type.
    """
    r = sd_bus_message_skip(bus_msg.c_obj, type.encode())
    check_msg_error(r)

# vim: sw=4:et:ai
