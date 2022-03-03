# st-edge/driver/bug

[SmartThings Edge Driver](https://community.smartthings.com/t/preview-smartthings-managed-edge-device-drivers)
to exhibit problem discussed [here](https://community.smartthings.com/t/try-create-device-though-device-may-be-added-not-always-init-ed).

## Usage

From the Devices tab in the SmartThings App, click **+**, **Add device** and **Scan for nearby devices**.
The log will show

```
DEBUG Bug  discovery	0
DEBUG Bug  create?	a455007a-daf1-51d4-b36c-1b5e6dc9ac5f	parent	Bug
DEBUG Bug  create!	a455007a-daf1-51d4-b36c-1b5e6dc9ac5f	parent	Bug
```

The first line reflects that there are 0 devices for this driver.
Devices will only be “discovered” when this is 0.
Later, discovery can be reattempted to see how many devices were actually created.

`create?` reflects the code’s attempt to acquire a counting `try_create_device_semaphore` that limits access to the `try_create_device` “resource” to 100 acquisitions.
`create!` reflects the code’s acquisition of such and the impending `try_create_device` call.
After `create?` (and `create!`) is the `device_network_id` (namespace UUID a455007a-daf1-51d4-b36c-1b5e6dc9ac5f), device model/type/sub_driver (parent) and label (Bug).

Give the system time to exhibit this bug.
It will try to create one “Bug” parent device with 100 “Bug #” children.
For each # (from 1 to 100), the log will show …

```
DEBUG Bug  create?	a455007a-daf1-51d4-b36c-1b5e6dc9ac5f	#	child	Bug #	74510a53-72bc-4b05-9ea0-551379ff92cd
DEBUG Bug  create!	a455007a-daf1-51d4-b36c-1b5e6dc9ac5f	#	child	Bug #	74510a53-72bc-4b05-9ea0-551379ff92cd
```

… where
the `device_network_id` matches that of the parent with a # suffix, the device model/type/sub_driver is “child”, the label is “Bug #” and the parent is specified by its UUID.

On subsequent discovery attempts, the log will show how many devices were created.
But not for this bug, one would/should expect …

```
DEBUG Bug  discovery	101
```

… but that is not what I see (more like 15).

My workaround is to change `try_create_device_semaphore` to a binary semaphore so that only one `try_create_device` can be done before the semaphore is released (which is done after `init`).

```
local try_create_device_semaphore = Semaphore()
```

To affect this change, remove the “Bug” parent device (this will remove it and all its children), uninstall, upload, assign and install this driver.
The first discovery will create all 101 devices.
As of this writing, this takes around 144 seconds (about 7 seconds per device).
