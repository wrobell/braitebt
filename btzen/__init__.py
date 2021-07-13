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

from .btweight import WeightFlags, WeightData, WeightMeasurement
from .ndevice import Device, register_device
from .cm import ConnectionManager, connect
from .serial import Serial
from .error import *

__version__ = pkg_resources.get_distribution('btzen').version

__all__ = ['Device', 'register_device']

# vim: sw=4:et:ai
