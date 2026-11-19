import CoreLocation
import Foundation

private enum MockBatteryStatus {
    case charging
}

private enum MockConnectedState {
    case online
}

private enum MockLocationType {
    case current
}

private struct MockAddress {
    let label: String?
    let mapItemFormattedAddress: String?
    let mediumAddressModern: String?
    let largeAddressModern: String?
    let locality: String?
    let administrativeArea: String?
    let countryCode: String?
}

private struct MockLocation {
    let location: CLLocation?
    let floor: Double?
    let isInaccurate: Bool
    let isLocationFinished: Bool
    let isOld: Bool
    let locationType: MockLocationType
}

private struct MockDevice {
    let identifier: String
    let name: String?
    let displayName: String?
    let model: String?
    let rawDeviceModel: String?
    let systemVersion: String?
    let batteryLevel: Double?
    let batteryStatus: MockBatteryStatus
    let deviceConnectedState: MockConnectedState
    let discoveryIdentifier: String?
    let baIdentifier: String?
    let category: String?
    let address: MockAddress?
    let location: MockLocation?
    let crowdSourcedLocation: MockLocation?
}

private struct MockDataManager {
    let devices: [MockDevice]
}

private struct MockManager {
    let dataManager: MockDataManager
}

private struct MockDevicesProvider {
    let fmipManager: MockManager
}

private struct MockMediator {
    let devicesProvider: MockDevicesProvider
}

private struct MockDataSource {
    let mediator: MockMediator
}

private func assert(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        print("FAIL: \(message)")
        exit(1)
    }
}

private func dataSource(devices: [MockDevice]) -> MockDataSource {
    return MockDataSource(
        mediator: MockMediator(
            devicesProvider: MockDevicesProvider(
                fmipManager: MockManager(
                    dataManager: MockDataManager(devices: devices)
                )
            )
        )
    )
}

private func device(
    identifier: String,
    name: String?,
    location: MockLocation?,
    discoveryIdentifier: String? = "00000000-0000-4000-8000-000000000001"
) -> MockDevice {
    return MockDevice(
        identifier: identifier,
        name: name,
        displayName: "MacBook Pro",
        model: "Mac14,6",
        rawDeviceModel: "Mac14,6-silver",
        systemVersion: "15.7.7",
        batteryLevel: 0,
        batteryStatus: .charging,
        deviceConnectedState: .online,
        discoveryIdentifier: discoveryIdentifier,
        baIdentifier: nil,
        category: "MacBookPro",
        address: MockAddress(
            label: "Seattle, WA",
            mapItemFormattedAddress: "Seattle, WA",
            mediumAddressModern: nil,
            largeAddressModern: nil,
            locality: "Seattle",
            administrativeArea: "WA",
            countryCode: "US"
        ),
        location: location,
        crowdSourcedLocation: nil
    )
}

private func testPopulatedAndOfflineDevices() {
    let timestamp = Date(timeIntervalSince1970: 1_234.567)
    let coreLocation = CLLocation(
        coordinate: CLLocationCoordinate2D(latitude: 47.61, longitude: -122.33),
        altitude: 32,
        horizontalAccuracy: 6.5,
        verticalAccuracy: 9,
        timestamp: timestamp
    )
    let currentLocation = MockLocation(
        location: coreLocation,
        floor: 4,
        isInaccurate: false,
        isLocationFinished: true,
        isOld: false,
        locationType: .current
    )

    let response = FindMyDeviceSnapshot.response(from: dataSource(devices: [
        device(identifier: "offline", name: "Zulu Device", location: nil),
        device(identifier: "online", name: "Alpha Device", location: currentLocation),
    ]))
    let devices = response["devices"] as? [[String: Any]]

    assert(response["error"] == nil, "a populated FMIP path must not return an error")
    assert(response["partial"] as? Bool == false, "identified records must form a complete snapshot")
    assert(devices?.count == 2, "online and offline devices must both remain in the snapshot")
    assert(devices?[0]["identifier"] as? String == "online", "devices must be sorted deterministically")
    assert(devices?[0]["batteryLevel"] as? Double == 0, "a zero battery level must not be treated as missing")
    assert(devices?[0]["batteryStatus"] as? String == "charging", "battery enum cases must be preserved")
    assert(devices?[0]["deviceConnectedState"] as? String == "online", "connection state must be preserved")
    assert(devices?[1]["location"] == nil, "an offline device must not gain a fabricated location")

    let location = devices?[0]["location"] as? [String: Any]
    assert(location?["latitude"] as? Double == 47.61, "latitude must be preserved")
    assert(location?["longitude"] as? Double == -122.33, "longitude must be preserved")
    let timestampMilliseconds = location?["timeStamp"] as? Double
    assert(abs((timestampMilliseconds ?? 0) - 1_234_567) < 0.001,
           "timestamps must be converted to milliseconds")
    assert(location?["floorLevel"] as? Double == 4, "floor level must be preserved")
    assert(location?["locationFinished"] as? Bool == true, "location completion state must be preserved")

    let address = devices?[0]["address"] as? [String: Any]
    assert(address?["mapItemFullAddress"] as? String == "Seattle, WA", "formatted address must be preserved")
    assert(address?["formattedAddressLines"] as? [String] == ["Seattle, WA"], "address lines must be explicit")
}

private func testUnavailableAndEmptyCollections() {
    let unavailable = FindMyDeviceSnapshot.response(from: NSObject())
    assert(unavailable["error"] as? String == "Find My Devices mediator is unavailable",
           "a missing app-owned object path must return an explicit error")

    let empty = FindMyDeviceSnapshot.response(from: dataSource(devices: []))
    assert((empty["devices"] as? [[String: Any]])?.isEmpty == true,
           "an initialized empty collection must remain distinguishable from an unavailable path")
    assert(empty["partial"] as? Bool == false, "an empty initialized collection must be complete")
}

private func testUnidentifiableDeviceMakesResponsePartial() {
    let response = FindMyDeviceSnapshot.response(from: dataSource(devices: [
        device(identifier: "   ", name: "Missing Identifier", location: nil, discoveryIdentifier: nil),
    ]))

    assert((response["devices"] as? [[String: Any]])?.isEmpty == true,
           "unidentifiable private records must not cross the API boundary")
    assert(response["partial"] as? Bool == true, "skipped private records must mark the response partial")
    assert(response["skippedDevices"] as? Int == 1, "skipped private records must be counted")
}

private struct MockFMFFriend {
    let identifier: String
    let contactHandles: Set<String>
    let displayName: String
}

private struct MockFMPeopleCellViewModel {
    let fullName: String
    let identifier: String
}

private final class MockFMFManager {
    let friends: [MockFMFFriend]
    init(friends: [MockFMFFriend]) {
        self.friends = friends
    }
}

private final class MockFMPeopleProvider {
    let fmfManager: MockFMFManager
    init(fmfManager: MockFMFManager) {
        self.fmfManager = fmfManager
    }
}

private final class MockFMConditionProvider: NSObject {
    var isFrontmostWindow = false
    var isWindowVisible = false
}

private final class MockPeopleMediator: NSObject {
    let peopleProvider: MockFMPeopleProvider
    let conditionProvider: MockFMConditionProvider
    init(peopleProvider: MockFMPeopleProvider, conditionProvider: MockFMConditionProvider) {
        self.peopleProvider = peopleProvider
        self.conditionProvider = conditionProvider
    }
}

private final class MockFMPeopleListDataSource: NSObject {
    let tableView: NSObject
    let delegate: NSObject
    let mediator: MockPeopleMediator
    let meCellViewModel: [MockFMPeopleCellViewModel]
    let fenceCellModels: [MockFMPeopleCellViewModel]
    let cellsViewModel: [MockFMPeopleCellViewModel]

    init(
        tableView: NSObject,
        delegate: NSObject,
        mediator: MockPeopleMediator,
        meCellViewModel: [MockFMPeopleCellViewModel],
        fenceCellModels: [MockFMPeopleCellViewModel],
        cellsViewModel: [MockFMPeopleCellViewModel]
    ) {
        self.tableView = tableView
        self.delegate = delegate
        self.mediator = mediator
        self.meCellViewModel = meCellViewModel
        self.fenceCellModels = fenceCellModels
        self.cellsViewModel = cellsViewModel
    }
}

private func testPeopleRowsMetadataExtraction() {
    let tableView = NSObject()
    let delegate = NSObject()
    let conditionProvider = MockFMConditionProvider()
    let fmfManager = MockFMFManager(friends: [
        MockFMFFriend(
            identifier: "friend-uuid-1",
            contactHandles: ["+15551234567", "alice@icloud.com"],
            displayName: "Alice Appleseed"
        ),
    ])
    let dataSource = MockFMPeopleListDataSource(
        tableView: tableView,
        delegate: delegate,
        mediator: MockPeopleMediator(
            peopleProvider: MockFMPeopleProvider(fmfManager: fmfManager),
            conditionProvider: conditionProvider
        ),
        meCellViewModel: [MockFMPeopleCellViewModel(fullName: "Me", identifier: "me-id")],
        fenceCellModels: [],
        cellsViewModel: [
            MockFMPeopleCellViewModel(fullName: "Bob Builder", identifier: "friend-uuid-2"),
            MockFMPeopleCellViewModel(fullName: "Alice Appleseed", identifier: "friend-uuid-1"),
        ]
    )

    let metadata = FindMyDeviceSnapshot.peopleRowsMetadata(from: dataSource)
    assert(metadata["tableView"] as? NSObject === tableView, "tableView must be extracted")
    assert(metadata["delegate"] as? NSObject === delegate, "delegate must be extracted")
    assert(metadata["conditionProvider"] as? MockFMConditionProvider === conditionProvider,
           "conditionProvider must be extracted")

    let friends = metadata["friends"] as? [[String]]
    assert(friends?.count == 1, "FMFManager friends must be extracted")
    assert(friends?[0].contains("+15551234567") == true, "friend contactHandles must be collected")

    let rows = metadata["rows"] as? [[String: Any]]
    assert(rows?.count == 3, "meCellViewModel (sec 0) and cellsViewModel (sec 2) rows must be extracted")
    assert(rows?[0]["section"] as? Int == 0 && rows?[0]["row"] as? Int == 0, "me row maps to section 0")
    assert(rows?[2]["section"] as? Int == 2 && rows?[2]["row"] as? Int == 1, "friend row 1 maps to section 2 row 1")
    let aliceTokens = rows?[2]["tokens"] as? [String] ?? []
    assert(aliceTokens.contains("Alice Appleseed") && aliceTokens.contains("friend-uuid-1"),
           "friend cell tokens must preserve display name and identifier")
}

@main
private enum FindMyDeviceSnapshotTests {
    static func main() {
        testPopulatedAndOfflineDevices()
        testUnavailableAndEmptyCollections()
        testUnidentifiableDeviceMakesResponsePartial()
        testPeopleRowsMetadataExtraction()
        print("PASS: FindMyDeviceSnapshotTests")
    }
}
