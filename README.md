# ChargingPowerMeter – iOS (SwiftUI)

An experimental iOS app that **estimates charging power (W)**, speed, and remaining time by tracking battery level over time.  
The UI is fully in Arabic with RTL layout and includes a dashboard, history view, and settings.

> ⚠️ All watt and time values are **estimates only** based on battery level changes, not direct hardware readings from iOS.

## Features

- Live battery level and charging state
- Estimated charging power in watts (W)
- Charging speed classification (slow / normal / fast)
- Estimated remaining time until full charge
- Charging history with average and max watt per session
- Arabic interface with RTL layout
- Dark mode support via `@AppStorage`

## Tech Stack

- SwiftUI
- Combine
- UIDevice Battery Monitoring
- MVVM-style `ChargingViewModel`
