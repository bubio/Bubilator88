import Testing
@testable import Bubilator88

struct OperationLockTests {

  /// Editing click zones pauses the machine: only operations that leave the
  /// machine and its disks alone may run.
  @Test func clickZoneEditingAllowsOnlyHarmlessOperations() {
    let allowed = LockableOperation.allCases.filter { OperationLock.clickZoneEditing.allows($0) }
    #expect(Set(allowed) == [.capture, .display, .audio])
  }
}
