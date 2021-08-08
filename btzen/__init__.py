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

import pkg_resources

# register devices
from . import serial as mod_serial
from . import sensortag
from . import thingy52
from . import bluez

from .btweight import WeightFlags, WeightData, MiScaleWeightData
from .data import AddressType, Button, Make, TriggerCondition, Trigger
from .device import DeviceBase, Device, DeviceTrigger, create_device, \
    accelerometer, battery_level, button, humidity, light, light_rgb, \
    pressure, serial, temperature, weight
from .service import Service, ServiceCharacteristic, ServiceInterface
from .fdevice import read, read_all, write, enable, disable, set_interval, \
    set_trigger, set_address_type
from .cm import connect
from .error import *
from .session import is_active
from .sensortag import SensorTagButtonState
from .thingy52 import Thingy52ButtonState

__version__ = pkg_resources.get_distribution('btzen').version

__all__ = [
    # bluetooth service descriptors
    'Service', 'ServiceCharacteristic', 'ServiceInterface',

    # basic data
    'Button',

    'is_active', 'read', 'read_all', 'write', 'set_interval',
    'set_trigger', 'set_address_type',

    # bluetooth device classes and functions
    'Make', 'DeviceBase', 'Device', 'DeviceTrigger', 'TriggerCondition',
    'AddressType', 'create_device', 'pressure', 'temperature', 'humidity',
    'light', 'light_rgb', 'accelerometer', 'button', 'serial', 'weight',
    'battery_level',

    # make specific objects
    'SensorTagButtonState', 'Thingy52ButtonState',
]

# vim: sw=4:et:ai
