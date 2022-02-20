# st-edge/driver/sundial

[SmartThings Edge Driver](https://community.smartthings.com/t/preview-smartthings-managed-edge-device-drivers)
for a sundial-like system that trips presence sensors at configured solar angles relative to an observer’s location.
These presence sensors are intended to be used as conditions or triggers in SmartThings Routines or Rules
instead of the cruder built-in sunrise/sunset times with minute offset capability.

This runs on your SmartThings hub without any external dependencies.

A Sundial behaves like a 24-hour mechanical timer with programmable on/off trippers except that
instead of controlling one switch with many trippers
it controls one presence sensor for each configured solar angle.

For each configured numeric angle, its associated presence sensor is

* **present** when the sun trips on the solar altitude angle relative to the dawn horizon and
* **not present** when the sun trips on the solar altitude angle relative to the dusk horizon.

Depending on the observer’s location, the day of the year and the configured angle,
it is posssible that sun will not trip on that solar altitude angle during the day.

For an angle of “morning”, its associated presence sensor is

* **present** when the sun trips on its lower culmination (at solar midnight when the solar altitude angle is closest to the observer’s nadir) and
* **not present** when the sun trips on its upper culmination (at solar noon when the solar altitude angle is closest to the observer’s zenith).

The following angles are configured by default

* **morning** Lower to upper [culmination](https://en.wikipedia.org/wiki/Culmination)s; otherwise, numeric [solar altitude angle](https://en.wikipedia.org/wiki/Solar_zenith_angle)s for
* **-18**	[Astronomical twilight](https://en.wikipedia.org/wiki/Twilight#Astronomical_twilight)
* **-12**	[Nautical twilight](https://en.wikipedia.org/wiki/Twilight#Nautical_twilight)
* **-6**	[Civil twilight](https://en.wikipedia.org/wiki/Twilight#Civil_twilight)
* **-0.833**	[Sunrise](https://en.wikipedia.org/wiki/Sunrise) & [Sunset](https://en.wikipedia.org/wiki/Sunset)
* **-0.3**	Sunrise end & Sunset start
* **6**		[Golden hour](https://en.wikipedia.org/wiki/Golden_hour_(photography))

These angles are described by the original
[suncalc](https://github.com/mourner/suncalc)
implementation which has been
[ported to lua](https://github.com/rtyle/suncalc-lua).
Calculations are credited and described [here](http://aa.quae.nl/en/reken/zonpositie.html).

## Usage

From the Devices tab in the SmartThings App, click **+**, **Add device** and **Scan for nearby devices**.
Give the system time to create your first Sundial (Sundial 1) and its default presence sensors.

Expect a bridge device to be created in SmartThings for each Sundial
and a device with **presenceSensor** capabilities for each tripped solar angle.

Use the settings of the Sundial bridge device to specify the observer’s location (Latitude, Longitude and Height).
To create another presense sensor on the sundial,
specify its numeric solar altitude **Angle** (between -90 and 90) or
specify the string **morning**.
If the presence sensor already exists, another will not be created.
To create another Sundial, set the **sundial** setting of an existing one to true and then back to false.

Removing the device for a Sundial will remove all of its associated presence sensor devices.
One can remove presence sensor devices and add them back.

