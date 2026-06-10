# Mac Workspace Launcher – Product Requirements Document (PRD)

## Overview

Build a native macOS application using SwiftUI that provides developers with an ultra-fast and elegant workspace launcher for VS Code and Cursor workspaces.

The primary goal of the application is to allow developers to instantly access and open any workspace from a global keyboard shortcut (⌘ + P) through a beautiful floating command palette interface, similar to Spotlight, Raycast, or Alfred.

The application should be lightweight, production-ready, highly optimized, visually polished, and designed following Apple's Human Interface Guidelines with full support for Light Mode and Dark Mode.

---

# Core Features

## 1. Automatic Workspace Discovery

The application should automatically discover and maintain a list of all VS Code and Cursor workspaces stored on the user's Mac.

Supported Sources:

* VS Code workspaces
* Cursor workspaces
* Recently opened projects
* User-defined workspace directories
* Git repositories (optional future enhancement)

The application should:

* Automatically scan configured directories
* Detect newly created workspaces
* Detect renamed workspaces
* Detect deleted workspaces
* Update workspace data in real-time

No manual refresh should be required.

---

## 2. Floating Command Palette

The main experience of the application.

### Global Shortcut

Default shortcut:

⌘ + P

Custom shortcuts should be configurable later.

### Behavior

When the user presses:

⌘ + P

The application displays a floating Spotlight-style panel.

The panel should:

* Appear instantly
* Animate smoothly
* Stay centered on screen
* Support multiple monitors
* Always stay above other windows

---

## 3. Workspace Search

The floating panel should contain:

### Search Bar

Real-time search with:

* Fuzzy search
* Prefix matching
* Workspace name matching
* Path matching
* Recent usage ranking

Results should update instantly while typing.

---

## 4. Keyboard Navigation

Users should be able to fully operate the application without a mouse.

### Keyboard Controls

↑ Move Up

↓ Move Down

Enter Open Workspace

Esc Close Panel

⌘ + P Toggle Panel

Tab Select Result

---

## 5. Open Workspace

When a workspace is selected:

### Preferred Method

Use:

code .

for VS Code

or

cursor .

for Cursor

### Fallback Logic

If CLI commands are unavailable:

1. Detect installed VS Code application
2. Detect installed Cursor application
3. Open workspace using macOS APIs
4. Open workspace directly via application path

Examples:

/Applications/Visual Studio Code.app

/Applications/Cursor.app

The application should automatically determine the best launch method.

---

# User Interface Design

## Design Goals

The application should feel:

* Native
* Modern
* Minimal
* Fast
* Professional
* Premium

Inspired by:

* Spotlight
* Raycast
* Arc Browser
* Linear
* Notion

---

## Workspace Cards

Each workspace item should display:

* Workspace Name
* Project Icon
* Last Opened Time
* Workspace Type
* Favorite Status

Optional:

* Git Branch
* Git Status
* Framework Badge

Examples:

Flutter

React

Node.js

Next.js

Vue

Swift

Rust

Go

---

## Animations

Use smooth SwiftUI animations:

* Spring animations
* Fade transitions
* Scale effects
* Hover effects
* Keyboard focus transitions

Target:

120 FPS smooth interactions.

---

# Performance Requirements

The application must feel instant.

### Startup

< 100ms

### Search Response

< 10ms

### Workspace Opening

< 200ms

### Memory Usage

< 100 MB

---

# Caching System

Implement a dedicated Workspace Cache Engine.

Store:

* Workspace metadata
* Last opened timestamp
* Favorites
* Recent usage
* Search index

The cache should:

* Load immediately on startup
* Update in the background
* Persist across launches

Recommended:

* SQLite
* SwiftData
* Lightweight indexing engine

---

# Real-Time Workspace Monitoring

Implement filesystem monitoring using:

* FSEvents
* DispatchSourceFileSystemObject

Features:

* Detect new workspaces
* Detect deleted workspaces
* Detect renamed workspaces
* Update UI instantly

No manual refresh required.

---

# Auto Launch at Login

Allow users to enable:

Launch at Login

When enabled:

* App starts automatically after Mac login
* Runs silently in background
* Appears in Menu Bar

---

# Menu Bar Integration

Provide a native macOS Menu Bar application.

Menu options:

* Open Workspace Launcher
* Recent Workspaces
* Favorites
* Settings
* Refresh Cache
* Quit

---

# Smart Features

## Favorites

Pin important workspaces.

## Recent Workspaces

Track most-used projects.

## Usage Analytics

Rank projects by:

* Frequency
* Recency
* Launch count

## Smart Suggestions

Show:

* Recently used
* Frequently used
* Active development projects

---

# Advanced Features

## Git Integration

Display:

* Current branch
* Uncommitted changes
* Ahead/Behind status

## Project Type Detection

Automatically detect:

* Flutter
* React
* Next.js
* Node.js
* Vue
* Angular
* Swift
* Rust
* Go
* Python

## Workspace Tags

Allow users to create:

* Work
* Personal
* Client
* Archived

Custom tags.

---

# Architecture

## Core Modules

### Workspace Discovery Engine

Responsible for:

* Scanning workspaces
* Detecting changes
* Managing updates

### Search Engine

Responsible for:

* Fuzzy search
* Ranking
* Filtering

### Cache Engine

Responsible for:

* Local persistence
* Fast loading
* Metadata storage

### Launch Engine

Responsible for:

* Opening VS Code
* Opening Cursor
* Fallback launching

### Hotkey Engine

Responsible for:

* Global shortcuts
* Floating panel activation

---

# Future Roadmap

### Phase 2

* Multiple custom shortcuts
* AI workspace recommendations
* Workspace notes
* Workspace groups
* Team-shared workspace collections

### Phase 3

* Cloud sync
* Cross-device sync
* Plugin system
* AI-powered project search

---

# Final Goal

Create the fastest, most beautiful, and most developer-friendly workspace launcher for macOS.

The experience should feel like a combination of Spotlight, Raycast, and Cursor, allowing developers to instantly find and open any workspace through a single keyboard shortcut with a native, polished, high-performance SwiftUI experience.
