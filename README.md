# CarBoard

Use any app on your car's CarPlay screen, or swap CarPlay's home screen for your iPhone's own home screen.

> **Tested on one setup only:** an iPhone XR on iOS 18.1 developer beta 4, jailbroken with Dopamine. That beta has some CarPlay quirks of its own, so other devices and iOS versions may behave differently. If something breaks on yours, please open an issue.

## What it does

### Any app on CarPlay
- Every app on your phone shows up on CarPlay, not just the ones made for it. Pick which ones in Settings.
- Apps open right next to CarPlay's sidebar and close with its home button, just like the built-in CarPlay apps. Prefer the old look? Turn off **Native CarPlay Look** and apps open full screen with their own little dock (home, full screen and rotate buttons).
- Apps are turned and resized to fit the car screen. You can make them bigger or smaller.
- **iPad Layout** opens apps the way they look on an iPad, with sidebars and split views, which suits the wide car screen.
- The keyboard shows up on the car screen when you tap a text field, and the app moves up so you can see what you're typing.
- Videos play on the car screen.
- Links open on the car too. If an app opens a website or another app, it opens on CarPlay instead of on your phone.
- **Permission Prompts on Car** (optional): permission requests and other system pop-ups from the app you're using show on the car screen, so you can answer them there.

### Your home screen on CarPlay
Tap **SpringBoard** in CarPlay's sidebar to get your iPhone's home screen on the car:
- Your icons and folders, laid out like on your phone. Move icons around and they stay where you put them.
- Your widgets, including the Today page.
- The App Library.
- Search, with a keyboard right on the car screen.
- Press home twice quickly to bring up an app switcher on the car.
- Press home to go back to your widgets or your first page.
- Pick how big the icons are and how many fit.

## Requirements
- A jailbroken iPhone on iOS 18 (rootless, for example Dopamine)
- ElleKit (or another tweak injector) and PreferenceLoader
- A car with CarPlay, or a CarPlay receiver

## Installing
1. Download the latest `.deb` from the [Releases](../../releases) page.
2. Open it with your package manager (Sileo or Zebra) or Filza, and install.
3. Your phone resprings. Connect to CarPlay and your apps are there.

## Settings
Open the **Settings** app and find **CarBoard**. You can:
- add or remove apps from CarPlay
- switch the native CarPlay look on or off
- change the app size, iPad layout and permission prompts
- change the home screen icon size, keep SpringBoard at the bottom of the sidebar, and show five apps in the sidebar
- set the dock side for the full-screen look

## Credits
Built on top of **carplay-cast** by Ethan Arbuckle. All of this started from that tweak, so a big thanks to them.

[carplay-cast's original repository](https://github.com/EthanArbuckle/carplay-cast)
