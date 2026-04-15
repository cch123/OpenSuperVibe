import AppKit

log("[SuperVibe] Starting...")

NSApplication.shared.setActivationPolicy(.accessory)

// Standard Edit menu so Cmd+V works in alert text fields
let mainMenu = NSMenu()
let editMenuItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
let editMenu = NSMenu(title: "Edit")
editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
editMenuItem.submenu = editMenu
mainMenu.addItem(editMenuItem)
NSApplication.shared.mainMenu = mainMenu

let delegate = AppDelegate()
NSApplication.shared.delegate = delegate
NSApplication.shared.run()
