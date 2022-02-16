# st-edge/driver/sundial

[SmartThings Edge Driver](https://community.smartthings.com/t/preview-smartthings-managed-edge-device-drivers)
for a sundial-like system that trips switches at configured solar angles relative to a location.
These switches are intended to be used as conditions or triggers in SmartThings Routines or Rules
instead of the cruder built-in sunrise/sunset times with minute offset capability.
Performance of these switches may account for a significant seasonal improvement in locations off the equator.

This runs on your SmartThings hub without any external dependencies.

A Sundial behaves like a 24-hour mechanical timer with programmable on/off trippers except that
instead of controlling one switch with many trippers
it controls one switch for each configured solar angle.

For each configured numeric angle, its associated switch is

* tripped on when the sun reaches the altitude angle relative to dawn and
* tripped off when the sun reaches the altitude angle relative to dusk.

An angle of "morning" will control one switch that will

* trip on when the sun reaches the nadir (solar midnight) azimuth angle (-180°) and
* trip off when the sun reaches the zenith (solar noon) azimuth angle (0°)

The following angles are configured by default

* **morning** Nadir to zenith [solar azimuth angle](https://en.wikipedia.org/wiki/Solar_azimuth_angle)s; otherwise, numeric [solar altitude angle](https://en.wikipedia.org/wiki/Solar_zenith_angle)s for
* **-18**		[Astronomical twilight](https://en.wikipedia.org/wiki/Twilight#Astronomical_twilight)
* **-12**		[Nautical twilight](https://en.wikipedia.org/wiki/Twilight#Nautical_twilight)
* **-6**		[Civil twilight](https://en.wikipedia.org/wiki/Twilight#Civil_twilight)
* **-0.833**	[Sunrise](https://en.wikipedia.org/wiki/Sunrise) & [Sunset](https://en.wikipedia.org/wiki/Sunset)
* **-0.3**		Sunrise end & Sunset start
* **6**		[Golden hour](https://en.wikipedia.org/wiki/Golden_hour_(photography))

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

Use the settings of the Sundial bridge device to specify your location (Latitude, Longitude and Height).
To create another switch on the sundial,
specify its numeric solar altitude **Angle** (between -90 and 90) or
specify the string **morning** for a switch that turns on at solar midnight and off at solar noon.
If the switch already exists, another will not be created.
To create another Sundial, set the **sundial** setting of an existing one to true and then back to false.

The on/off status of each switch is only affected by the configured location and solar angle.
The switches cannot be manipulated otherwise.

Removing the device for a Sundial will remove all of its associated devices.
