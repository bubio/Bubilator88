import SwiftUI

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

  var body: some Commands {
    CommandMenu("Disk") {
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

    CommandMenu("Tape") {
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
  }
}
