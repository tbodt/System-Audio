# System Audio

A macOS audio driver that provides an input device that sends all audio outputted on the system.

To build from source, clone the repository and run this command:

```
sudo xcodebuild install DSTROOT=/ && sudo killall -9 coreaudiod
```

Currently only works on Catalina and is broken on Big Sur. Working on a fix.
