import SwiftUI
import Bubilator88Core

/// Disk Menu
struct DiskCommands: Commands {
  let viewModel: EmulatorViewModel

  @ViewBuilder
  private func driveSubmenu(drive: Int) -> some View {
    let label = drive + 1
    let name = drive == 0 ? viewModel.drive0Name : viewModel.drive1Name
    let fileName = drive == 0 ? viewModel.drive0FileName : viewModel.drive1FileName
    let info = drive == 0 ? viewModel.drive0Info : viewModel.drive1Info
    let shortcut: KeyEquivalent = drive == 0 ? "1" : "2"

    Menu {
      Button {
        viewModel.diskPickerDrive = drive
        viewModel.showingDiskPicker = true
      } label: {
        Label("Mount...", systemImage: "opticaldiscdrive")
      }
      .keyboardShortcut(shortcut, modifiers: .command)

      Button {
        viewModel.ejectDisk(drive: drive)
      } label: {
        Label("Eject", systemImage: "eject")
      }
      .disabled(name == "Empty")

      let wp = drive == 0 ? viewModel.drive0WriteProtected : viewModel.drive1WriteProtected
      Button {
        viewModel.toggleWriteProtect(drive: drive)
      } label: {
        if wp {
          Label("Write Protect ✓", systemImage: "lock.fill")
        } else {
          Label("Write Protect", systemImage: "lock.open")
        }
      }
      .disabled(name == "Empty")

      if name != "Empty", let fileName {
        Divider()
        Text(fileName).disabled(true)
      }

      if let info {
        let multiGroup = info.imageGroups.count > 1
        ForEach(info.imageGroups, id: \.startIndex) { group in
          if multiGroup {
            Text(group.d88FileName).disabled(true)
          }
          ForEach(0..<group.count, id: \.self) { offset in
            let index = group.startIndex + offset
            Button {
              viewModel.switchDiskImage(drive: drive, index: index)
            } label: {
              let imgName = info.imageNames[index]
              if index == info.currentImageIndex {
                Text(multiGroup ? "  \(imgName) ✓" : "\(imgName) ✓")
              } else {
                Text(multiGroup ? "  \(imgName)" : imgName)
              }
            }
          }
        }
      }
    } label: {
      Label("Drive \(label)", image: "FloppyDisk")
    }
  }

  /// The 88PAR groups of the cheat file imported for the mounted disks.
  @ViewBuilder
  private var cheatsSubmenu: some View {
    let set = viewModel.activeCheatSet
    Menu {
      if let set {
        Text(set.name).disabled(true)
        let groups = CheatStore.shared.groups(of: set)
        ForEach(groups.indices, id: \.self) { index in
          Toggle(groups[index].name.isEmpty ? PATFile.unnamedGroupName : groups[index].name,
                 isOn: Binding(
                   get: { viewModel.isCheatGroupEnabled(index) },
                   set: { viewModel.setCheatGroup(index, enabled: $0) }))
        }
        Divider()
        Button("Disable All Cheats") {
          viewModel.disableAllCheats()
        }
        .disabled(set.enabledGroups.isEmpty)
        Divider()
      }
      let noDisk = viewModel.drive0Info == nil && viewModel.drive1Info == nil
      Menu("Presets") {
        ForEach(CheatStore.shared.presets, id: \.title) { preset in
          Button(preset.title) {
            viewModel.useCheatPreset(preset)
          }
        }
      }
      .disabled(noDisk)
      Button("Import Cheat File...") {
        viewModel.openCheatFile()
      }
      .disabled(noDisk)
    } label: {
      Label("Cheats", systemImage: "wand.and.stars")
    }
  }

  var body: some Commands {
    CommandMenu("Disk") {
      Group {
        // Drive 1 submenu
        driveSubmenu(drive: 0)

        // Drive 2 submenu
        driveSubmenu(drive: 1)

        Divider()

        Menu {
          Button {
            viewModel.diskPickerDrive = -1
            viewModel.showingDiskPicker = true
          } label: {
            Label("Mount...", systemImage: "opticaldiscdrive")
          }
          .keyboardShortcut("3", modifiers: .command)

          Button {
            viewModel.ejectDisk(drive: 0)
            viewModel.ejectDisk(drive: 1)
          } label: {
            Label("Eject", systemImage: "eject")
          }
          .disabled(viewModel.drive0Name == "Empty" && viewModel.drive1Name == "Empty")
        } label: {
          Label("Drive 1&2", image: "FloppyDisk")
        }

        Divider()

        cheatsSubmenu

        Divider()

        Button {
          viewModel.createBlankDisk()
        } label: {
          Label("Create Blank Disk...", systemImage: "plus.circle")
        }
        .keyboardShortcut("n", modifiers: [.command, .shift])

        Button {
          viewModel.exportCachedDisks()
        } label: {
          Label("Export Cached Disks...", systemImage: "square.and.arrow.up")
        }

        Divider()

        // Recent Files submenu
        Menu("Recent Files") {
          if Settings.shared.recentDiskFiles.isEmpty {
            Text("No Recent Files")
          } else {
            ForEach(Settings.shared.recentDiskFiles) { entry in
              Button("\(entry.displayName) — \(entry.displayDir)") {
                viewModel.mountRecentFile(entry)
              }
            }
            Divider()
            Button {
              Settings.shared.clearRecentFiles()
            } label: {
              Label("Clear Recent Files", systemImage: "trash")
            }
          }
        }
      }
      .disabled(!viewModel.allows(.media))
    }

    CommandMenu("Tape") {
      Group {
        Text(viewModel.tapeDisplayLabel).disabled(true)

        Divider()

        Button {
          viewModel.showingTapePicker = true
        } label: {
          Label {
            Text("Open...")
          } icon: {
            Image("Cassete")
          }
        }
        .keyboardShortcut("t", modifiers: [.command, .shift])

        Button {
          viewModel.rewindTape()
        } label: {
          Label("Rewind", systemImage: "backward.end")
        }
        .disabled(!viewModel.isTapeMounted)

        Button {
          viewModel.ejectTape()
        } label: {
          Label("Eject", systemImage: "eject")
        }
        .disabled(!viewModel.isTapeMounted)

        Divider()

        Menu("Recent Files") {
          if Settings.shared.recentTapeFiles.isEmpty {
            Text("No Recent Files")
          } else {
            ForEach(Settings.shared.recentTapeFiles) { entry in
              Button("\(entry.displayName) — \(entry.displayDir)") {
                viewModel.mountRecentTape(entry)
              }
            }
            Divider()
            Button {
              Settings.shared.clearRecentTapeFiles()
            } label: {
              Label("Clear Recent Files", systemImage: "trash")
            }
          }
        }
      }
      .disabled(!viewModel.allows(.media))
    }
  }
}
