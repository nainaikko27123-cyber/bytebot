# Byte 🤖

A small AI desktop robot that lives on your Mac. Byte walks around your screen, talks back with a real voice, and answers your questions with Google Gemini.

## Features
- **AI brain:** chat with Byte, powered by the Google Gemini API (picks the newest Flash model automatically)
- **Spoken replies:** uses macOS text-to-speech, and Byte's mouth moves with each word
- **Smooth 60fps animation:** rolls around on crawler tracks, blinks, follows your mouse with its eyes, and hops happily when you pet it
- **Stays out of the way:** floating window with a menu-bar icon and no Dock icon
- **Keeps your API key safe:** stored in the macOS Keychain, never in the code

## Built with
Swift · SwiftUI · AppKit · AVFoundation · Gemini REST API

## Run it
```bash
./build.sh
```
This builds `Byte.app` into `~/Applications`. On first launch Byte asks for a free Gemini API key from [aistudio.google.com/apikey](https://aistudio.google.com/apikey).
