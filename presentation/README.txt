How can I change the minimum dimmer presentation for my Edge driver from 0 to 1?

https://community.smartthings.com/t/how-can-i-change-the-minimum-dimmer-presentation-for-my-edge-driver-from-0-to-1/238131

# for the structure,
# start with a devices:presentation for a dimmer device (by $device_id) that needs to be changed

	./smartthings devices:presentation -y $device_id > presentation/dimmer-devices-presentation.yaml

# copy and edit

	cp presentation/dimmer{-devices-presentation,}.yaml
	vi presentation/dimmer.yaml

		# at the trunk, remove everything but the dashboard, detailView and automation branches.
		# at the tips of the remaining branches, remove everything but

			- component: main
			  capability: *
			  version: 1

		# for all the capability: switchLevel tips, add

			values:
			  - key: level.value
			    range:
			      - 1
			      - 100
			    step: 1

# create presentation/dimmer-presentation-device-config.yaml

	./smartthings presentation:device-config:create -i presentation/dimmer.yaml > presentation/dimmer-presentation-device-config.yaml

# some of this information needs to be appended to profiles/dimmer.yaml

	(echo metadata:; head -2 presentation/dimmer-presentation-device-config.yaml | sed 's/^/  /') >> profiles/dimmer.yaml
