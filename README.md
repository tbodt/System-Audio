# System Audio

A macOS audio driver that provides an input device that sends all audio outputted on the system.

A prebuilt binary can be downloaded [here](../../releases/download/v1.0/System.Audio.driver.zip). To install:
- Uncompress and copy System Audio.driver to /Library/Audio/Plug-Ins/HAL.
- If you downloaded it from a web browser, `xattr -dr com.apple.quarantine "/Library/Audio/Plug-Ins/HAL/System Audio.driver"` may be necessary to convince macOS that the app is not in fact damanged and should be moved to the trash.
- Reboot your computer, or run `sudo killall -9 coreaudiod` to make coreaudiod reload the driver.

To build from source, clone the repository and run this command:

```
sudo xcodebuild install DSTROOT=/ && sudo killall -9 coreaudiod
```

Currently only works on Catalina and is broken on Big Sur. Working on a fix.
