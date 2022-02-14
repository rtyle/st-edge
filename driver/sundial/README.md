# st-edge/driver/sundial

[SmartThings Edge Driver](https://community.smartthings.com/t/preview-smartthings-managed-edge-device-drivers)
for a sundial-like system that trips switches at configured solar angles relative to a location.
These switches are intended to be used as conditions or triggers in SmartThings Routines or Rules
instead of the cruder built-in sunrise/sunset times with minute offset capability.
Performance of these switches may account for a significant seasonal improvement in locations off the equator.

This runs on your SmartThings hub without any external dependencies.

A Sundial behaves like a 24-hour mechanical timer with programmable on/off trippers except that
instead of controlling one switch with many trippers
it controls one switch for each configured solar angle relative to the horizon.

For each configured angle, its associated switch is

* tripped on when the sun reaches that angle relative to dawn and
* tripped off when the sun reaches that angle relative to dusk.

An angle of -90 is treated the same as an angle of 90 and will control one switch that will

* trip on when the sun reaches its nadir (solar midnight) and
* trip off when the sun reaches its zenith (solar noon).

The following angles are configured by default

* -90|90	Nadir & Zenith
* -18		Astronomical twilight
* -12		Nautical twilight
* -6		Civil twilight
* -0.833	Sunrise & Sunset
* -0.3		Sunrise end & Sunset start
* 6		Golden hour

These angles are described by the original
[suncalc](https://github.com/mourner/suncalc)
implementation which has been
[ported to lua](https://github.com/rtyle/suncalc-lua).
Calculations are credited and described [here](http://aa.quae.nl/en/reken/zonpositie.html).

## Usage

From the Devices tab in the SmartThings App, click **+**, **Add device** and **Scan for nearby devices**.
Give the system time to create your first Sundial (Sundial 1) and its switches.

Expect a bridge device to be created in SmartThings for each Sundial
and a device with Switch capabilities for each tripped angle.

The on/off status of each switch is only affected by the configured location and solar angle.
The switches cannot be manipulated otherwise.

Removing the device for a Sundial will remove all of its associated devices.
