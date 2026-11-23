import CoreLocation
import Foundation

enum FindMyDeviceSnapshot {
    static func response(from dataSource: Any) -> [String: Any] {
        guard let mediator = resolveMediator(from: dataSource) else {
            return errorResponse("Find My Devices mediator is unavailable")
        }
        guard let devicesProvider = child(named: "devicesProvider", in: mediator) else {
            return errorResponse("Find My Devices provider is unavailable")
        }
        guard let manager = child(named: "fmipManager", in: devicesProvider) else {
            return errorResponse("Find My Devices manager is unavailable")
        }
        guard let dataManager = child(named: "dataManager", in: manager) else {
            return errorResponse("Find My Devices data manager is unavailable")
        }
        guard let devices = child(named: "devices", in: dataManager) else {
            return errorResponse("Find My Devices collection is unavailable")
        }

        let devicesMirror = Mirror(reflecting: devices)
        guard devicesMirror.displayStyle == .collection else {
            return errorResponse("Find My Devices collection has an unexpected type")
        }

        var skippedDeviceCount = 0
        let serializedDevices = devicesMirror.children.compactMap { child -> [String: Any]? in
            guard let device = serializeDevice(child.value) else {
                skippedDeviceCount += 1
                return nil
            }
            return device
        }.sorted(by: deviceSortOrder)

        return [
            "devices": serializedDevices,
            "partial": skippedDeviceCount > 0,
            "skippedDevices": skippedDeviceCount,
        ]
    }

    static func fmipManager(from dataSource: Any) -> AnyObject? {
        guard let mediator = resolveMediator(from: dataSource),
              let devicesProvider = child(named: "devicesProvider", in: mediator),
              let manager = child(named: "fmipManager", in: devicesProvider) else {
            return nil
        }
        // Only bridge real Swift/ObjC class instances; unit-test struct mocks are not HeapObjects.
        guard Mirror(reflecting: manager).displayStyle == .class else {
            return nil
        }
        return manager as AnyObject
    }

    static func fmfManager(from container: Any) -> AnyObject? {
        guard let mediator = resolveMediator(from: container),
              let peopleProvider = child(named: "peopleProvider", in: mediator),
              let manager = child(named: "fmfManager", in: peopleProvider) else {
            return nil
        }
        guard Mirror(reflecting: manager).displayStyle == .class else {
            return nil
        }
        return manager as AnyObject
    }

    static func childObject(named name: String, in object: Any) -> AnyObject? {
        guard let value = child(named: name, in: object),
              Mirror(reflecting: value).displayStyle == .class else {
            return nil
        }
        return value as AnyObject
    }

    private static func resolveMediator(from container: Any) -> Any? {
        if let mediator = child(named: "mediator", in: container) {
            return mediator
        }
        if child(named: "peopleProvider", in: container) != nil ||
           child(named: "devicesProvider", in: container) != nil ||
           child(named: "conditionProvider", in: container) != nil {
            return container
        }
        return nil
    }

    private static func errorResponse(_ message: String) -> [String: Any] {
        return [
            "error": message,
            "devices": [],
        ]
    }

    private static func serializeDevice(_ value: Any) -> [String: Any]? {
        guard let identifier = firstString(
            named: ["identifier", "discoveryIdentifier", "baIdentifier"],
            in: value
        ) else {
            return nil
        }

        var device: [String: Any] = ["identifier": identifier]
        for key in ["name", "displayName", "model", "rawDeviceModel", "systemVersion", "discoveryIdentifier", "baIdentifier", "category"] {
            copyString(named: key, from: value, to: &device)
        }

        if let batteryLevel = number(child(named: "batteryLevel", in: value)) {
            device["batteryLevel"] = batteryLevel
        }
        if let batteryStatus = enumCase(child(named: "batteryStatus", in: value)) {
            device["batteryStatus"] = batteryStatus
        }
        if let connectedState = enumCase(child(named: "deviceConnectedState", in: value)) {
            device["deviceConnectedState"] = connectedState
        }
        if let address = serializeAddress(child(named: "address", in: value)) {
            device["address"] = address
        }
        if let location = serializeLocation(child(named: "location", in: value)) {
            device["location"] = location
        }
        if let crowdSourcedLocation = serializeLocation(child(named: "crowdSourcedLocation", in: value)) {
            device["crowdSourcedLocation"] = crowdSourcedLocation
        }

        return device
    }

    private static func serializeAddress(_ value: Any?) -> [String: Any]? {
        guard let address = unwrapped(value) else {
            return nil
        }

        var serializedAddress: [String: Any] = [:]
        for key in ["label", "countryCode", "administrativeArea", "locality"] {
            copyString(named: key, from: address, to: &serializedAddress)
        }

        if let formattedAddress = firstString(
            named: ["mapItemFormattedAddress", "largeAddressModern", "mediumAddressModern", "label"],
            in: address
        ) {
            serializedAddress["mapItemFullAddress"] = formattedAddress
            serializedAddress["formattedAddressLines"] = [formattedAddress]
        }

        return serializedAddress.isEmpty ? nil : serializedAddress
    }

    private static func serializeLocation(_ value: Any?) -> [String: Any]? {
        guard let locationWrapper = unwrapped(value) else {
            return nil
        }

        let coreLocation: CLLocation?
        if let directLocation = locationWrapper as? CLLocation {
            coreLocation = directLocation
        } else {
            coreLocation = unwrapped(child(named: "location", in: locationWrapper)) as? CLLocation
        }
        guard let coreLocation else {
            return nil
        }

        let coordinate = coreLocation.coordinate
        guard CLLocationCoordinate2DIsValid(coordinate),
              coordinate.latitude.isFinite,
              coordinate.longitude.isFinite else {
            return nil
        }

        var serializedLocation: [String: Any] = [
            "latitude": coordinate.latitude,
            "longitude": coordinate.longitude,
            "timeStamp": coreLocation.timestamp.timeIntervalSince1970 * 1_000,
        ]
        copyAccuracy(coreLocation.horizontalAccuracy, named: "horizontalAccuracy", to: &serializedLocation)
        copyAccuracy(coreLocation.verticalAccuracy, named: "verticalAccuracy", to: &serializedLocation)
        copyFinite(coreLocation.altitude, named: "altitude", to: &serializedLocation)

        if let floorLevel = number(child(named: "floor", in: locationWrapper)) {
            serializedLocation["floorLevel"] = floorLevel
        } else if let floorLevel = coreLocation.floor?.level {
            serializedLocation["floorLevel"] = floorLevel
        }
        for (sourceKey, destKey) in [("isInaccurate", "isInaccurate"), ("isOld", "isOld"), ("isLocationFinished", "locationFinished")] {
            if let flag = boolean(child(named: sourceKey, in: locationWrapper)) {
                serializedLocation[destKey] = flag
            }
        }
        if let locationType = enumCase(child(named: "locationType", in: locationWrapper)) {
            serializedLocation["positionType"] = locationType
        }

        return serializedLocation
    }

    private static func copyString(named name: String, from source: Any, to destination: inout [String: Any]) {
        if let value = string(child(named: name, in: source)) {
            destination[name] = value
        }
    }

    private static func copyFinite(_ value: Double, named name: String, to destination: inout [String: Any]) {
        if value.isFinite {
            destination[name] = value
        }
    }

    private static func copyAccuracy(_ value: Double, named name: String, to destination: inout [String: Any]) {
        if value.isFinite, value >= 0 {
            destination[name] = value
        }
    }

    private static func firstString(named names: [String], in value: Any) -> String? {
        return names.lazy.compactMap { string(child(named: $0, in: value)) }.first
    }

    private static func child(named name: String, in value: Any) -> Any? {
        guard let root = unwrapped(value) else {
            return nil
        }

        var mirror: Mirror? = Mirror(reflecting: root)
        while let currentMirror = mirror {
            if let child = currentMirror.children.first(where: { $0.label == name }) {
                return unwrapped(child.value)
            }
            mirror = currentMirror.superclassMirror
        }
        return nil
    }

    private static func unwrapped(_ value: Any?) -> Any? {
        guard var currentValue = value else {
            return nil
        }

        while Mirror(reflecting: currentValue).displayStyle == .optional {
            guard let wrappedValue = Mirror(reflecting: currentValue).children.first?.value else {
                return nil
            }
            currentValue = wrappedValue
        }
        return currentValue
    }

    private static func string(_ value: Any?) -> String? {
        guard let unwrappedValue = unwrapped(value) else {
            return nil
        }

        let candidate: String?
        if let stringValue = unwrappedValue as? String {
            candidate = stringValue
        } else if let uuidValue = unwrappedValue as? UUID {
            candidate = uuidValue.uuidString
        } else {
            candidate = nil
        }

        let trimmedValue = candidate?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedValue?.isEmpty == false ? trimmedValue : nil
    }

    private static func number(_ value: Any?) -> Double? {
        guard let unwrappedValue = unwrapped(value), !(unwrappedValue is Bool) else {
            return nil
        }

        let numericValue: Double?
        if let numberValue = unwrappedValue as? NSNumber {
            numericValue = numberValue.doubleValue
        } else if let doubleValue = unwrappedValue as? Double {
            numericValue = doubleValue
        } else if let floatValue = unwrappedValue as? Float {
            numericValue = Double(floatValue)
        } else if let integerValue = unwrappedValue as? Int {
            numericValue = Double(integerValue)
        } else {
            numericValue = nil
        }

        guard let numericValue, numericValue.isFinite else {
            return nil
        }
        return numericValue
    }

    private static func boolean(_ value: Any?) -> Bool? {
        return unwrapped(value) as? Bool
    }

    private static func enumCase(_ value: Any?) -> String? {
        guard let unwrappedValue = unwrapped(value) else {
            return nil
        }
        if let stringValue = string(unwrappedValue) {
            return stringValue
        }

        let mirror = Mirror(reflecting: unwrappedValue)
        guard mirror.displayStyle == .enum else {
            return nil
        }
        if let caseName = mirror.children.first?.label, !caseName.isEmpty {
            return caseName
        }

        let caseName = String(describing: unwrappedValue)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return caseName.isEmpty ? nil : caseName
    }

    private static func deviceSortOrder(_ left: [String: Any], _ right: [String: Any]) -> Bool {
        let leftName = (left["name"] as? String) ?? (left["displayName"] as? String) ?? ""
        let rightName = (right["name"] as? String) ?? (right["displayName"] as? String) ?? ""
        let nameComparison = leftName.localizedCaseInsensitiveCompare(rightName)
        if nameComparison != .orderedSame {
            return nameComparison == .orderedAscending
        }

        let leftIdentifier = left["identifier"] as? String ?? ""
        let rightIdentifier = right["identifier"] as? String ?? ""
        return leftIdentifier < rightIdentifier
    }

    static func peopleRowsMetadata(from dataSource: Any) -> [String: Any] {
        var result: [String: Any] = [:]

        if let tableView = child(named: "tableView", in: dataSource) {
            result["tableView"] = tableView
        }
        if let delegate = child(named: "delegate", in: dataSource) {
            result["delegate"] = delegate
        }

        var friendTokenGroups: [[String]] = []
        if let mediator = resolveMediator(from: dataSource) {
            result["mediator"] = mediator
            if let conditionProvider = child(named: "conditionProvider", in: mediator) {
                result["conditionProvider"] = conditionProvider
            }
            if let peopleProvider = child(named: "peopleProvider", in: mediator),
               let fmfManager = child(named: "fmfManager", in: peopleProvider) {
                for friend in fmfFriends(from: fmfManager) {
                    let tokens = collectStringTokens(from: friend, maxDepth: 5)
                    if !tokens.isEmpty {
                        friendTokenGroups.append(tokens)
                    }
                }
            }
        }
        result["friends"] = friendTokenGroups

        // FMPeopleListDataSource section mapping: 0 = meCellViewModel, 1 = fenceCellModels, 2 = cellsViewModel.
        let sectionSources: [(Int, String)] = [
            (0, "meCellViewModel"),
            (1, "fenceCellModels"),
            (2, "cellsViewModel"),
        ]
        var rows: [[String: Any]] = []
        for (section, ivarName) in sectionSources {
            guard let sectionValue = child(named: ivarName, in: dataSource) else {
                continue
            }
            for (rowIndex, element) in collectionElements(sectionValue).enumerated() {
                rows.append([
                    "section": section,
                    "row": rowIndex,
                    "tokens": collectStringTokens(from: element, maxDepth: 5),
                ])
            }
        }
        result["rows"] = rows
        return result
    }

    static func withMatchingFriend(
        in container: Any,
        targets: [String],
        body: (AnyObject, UnsafeRawPointer) -> Void
    ) -> Bool {
        let cleanedTargets = targets.compactMap { normalizedMatchString($0) }
        guard !cleanedTargets.isEmpty,
              let manager = fmfManager(from: container) else {
            return false
        }

        let friends = fmfFriends(from: manager)
        guard !friends.isEmpty else {
            return false
        }

        // Pass 1: exact handle/phone/email match against identifier, contactHandles, pushIdentifiers.
        var matchedFriend: Any?
        for friend in friends {
            let handleTokens = friendHandleTokens(from: friend)
            if handleTokens.contains(where: { token in
                cleanedTargets.contains(where: { target in
                    matchToken(token, against: target, allowNameMatch: false)
                })
            }) {
                matchedFriend = friend
                break
            }
        }

        // Pass 2: fallback to displayName / shortName / general string tokens.
        if matchedFriend == nil {
            for friend in friends {
                let tokens = collectStringTokens(from: friend, maxDepth: 4)
                if tokens.contains(where: { token in
                    cleanedTargets.contains(where: { target in
                        matchToken(token, against: target, allowNameMatch: true)
                    })
                }) {
                    matchedFriend = friend
                    break
                }
            }
        }

        guard let friend = matchedFriend,
              let equatableFriend = friend as? any Equatable else {
            return false
        }

        openEquatablePointer(equatableFriend) { friendPtr in
            body(manager, friendPtr)
        }
        return true
    }

    private static func openEquatablePointer<T: Equatable>(
        _ value: T,
        _ body: (UnsafeRawPointer) -> Void
    ) {
        withUnsafePointer(to: value) { ptr in
            body(UnsafeRawPointer(ptr))
        }
    }

    private static func fmfFriends(from fmfManager: Any) -> [Any] {
        // FMFCore.FMFManager stores friends on dataManager.internalFriends; keep .friends fallback for mocks/older macOS.
        if let dataManager = child(named: "dataManager", in: fmfManager),
           let internalFriends = child(named: "internalFriends", in: dataManager) {
            let elements = collectionElements(internalFriends)
            if !elements.isEmpty {
                return elements
            }
        }
        if let friends = child(named: "friends", in: fmfManager) {
            return collectionElements(friends)
        }
        return []
    }

    private static func friendHandleTokens(from friend: Any) -> [String] {
        var tokens: [String] = []
        var seen: Set<String> = []
        for field in ["identifier", "contactHandles", "pushIdentifiers", "handle", "handles", "aliases"] {
            guard let value = child(named: field, in: friend) else {
                continue
            }
            for item in collectionElements(value) {
                if let str = string(item), seen.insert(str).inserted {
                    tokens.append(str)
                }
            }
        }
        return tokens
    }

    private static func normalizedMatchString(_ value: String) -> String? {
        var trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        if lower.hasPrefix("mailto:") {
            trimmed = String(trimmed.dropFirst(7)).trimmingCharacters(in: .whitespacesAndNewlines)
        } else if lower.hasPrefix("tel:") {
            trimmed = String(trimmed.dropFirst(4)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let collapsed = trimmed.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        return collapsed.isEmpty ? nil : collapsed
    }

    private static func digitsOnly(_ value: String) -> String {
        return String(value.unicodeScalars.filter { CharacterSet.decimalDigits.contains($0) })
    }

    private static func hasLetters(_ value: String) -> Bool {
        return value.unicodeScalars.contains { CharacterSet.letters.contains($0) }
    }

    private static func matchToken(_ candidate: String, against target: String, allowNameMatch: Bool) -> Bool {
        guard let cleanCandidate = normalizedMatchString(candidate),
              let cleanTarget = normalizedMatchString(target) else {
            return false
        }
        let compareOptions: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        if cleanCandidate.compare(cleanTarget, options: compareOptions) == .orderedSame {
            return true
        }
        if !cleanCandidate.contains("@"),
           !cleanTarget.contains("@"),
           !hasLetters(cleanCandidate),
           !hasLetters(cleanTarget) {
            let candDigits = digitsOnly(cleanCandidate)
            let targetDigits = digitsOnly(cleanTarget)
            if candDigits.count >= 7 && targetDigits.count >= 7 {
                if candDigits == targetDigits {
                    return true
                }
                if min(candDigits.count, targetDigits.count) >= 10 &&
                   (candDigits.hasSuffix(targetDigits) || targetDigits.hasSuffix(candDigits)) {
                    return true
                }
            }
        }
        if allowNameMatch && cleanTarget.count >= 3 && hasLetters(cleanTarget) && !cleanTarget.contains("@") {
            return cleanCandidate.range(of: cleanTarget, options: compareOptions) != nil
        }
        return false
    }

    private static func collectionElements(_ value: Any?) -> [Any] {
        guard let unwrappedValue = unwrapped(value) else {
            return []
        }
        let mirror = Mirror(reflecting: unwrappedValue)
        if mirror.displayStyle == .collection || mirror.displayStyle == .set {
            return mirror.children.map { $0.value }
        }
        if mirror.displayStyle == .dictionary {
            return mirror.children.compactMap { entry in
                let pairMirror = Mirror(reflecting: entry.value)
                return pairMirror.children.dropFirst().first?.value
            }
        }
        return [unwrappedValue]
    }

    private static func collectStringTokens(from value: Any?, maxDepth: Int) -> [String] {
        var tokens: [String] = []
        var seenTokens: Set<String> = []
        var visitedObjects: Set<ObjectIdentifier> = []
        appendStringTokens(
            from: value,
            depth: 0,
            maxDepth: maxDepth,
            tokens: &tokens,
            seenTokens: &seenTokens,
            visitedObjects: &visitedObjects
        )
        return tokens
    }

    private static func appendStringTokens(
        from value: Any?,
        depth: Int,
        maxDepth: Int,
        tokens: inout [String],
        seenTokens: inout Set<String>,
        visitedObjects: inout Set<ObjectIdentifier>
    ) {
        guard let unwrappedValue = unwrapped(value) else {
            return
        }
        if let str = string(unwrappedValue) {
            if seenTokens.insert(str).inserted {
                tokens.append(str)
            }
            return
        }
        guard depth < maxDepth else {
            return
        }

        let mirror = Mirror(reflecting: unwrappedValue)
        if mirror.displayStyle == .collection || mirror.displayStyle == .set {
            for child in mirror.children.prefix(64) {
                appendStringTokens(
                    from: child.value,
                    depth: depth + 1,
                    maxDepth: maxDepth,
                    tokens: &tokens,
                    seenTokens: &seenTokens,
                    visitedObjects: &visitedObjects
                )
            }
            return
        }

        if mirror.displayStyle == .class {
            let objectID = ObjectIdentifier(unwrappedValue as AnyObject)
            if !visitedObjects.insert(objectID).inserted {
                return
            }
        }

        let ignoredLabels: Set<String> = [
            "tableView", "delegate", "mediator", "updateQueue", "delayedUpdateWorkItem",
            "cancellables", "subscriptions", "avatar", "image", "cachedImage", "icon",
        ]
        var currentMirror: Mirror? = mirror
        while let activeMirror = currentMirror {
            for child in activeMirror.children {
                if let label = child.label, ignoredLabels.contains(label) {
                    continue
                }
                appendStringTokens(
                    from: child.value,
                    depth: depth + 1,
                    maxDepth: maxDepth,
                    tokens: &tokens,
                    seenTokens: &seenTokens,
                    visitedObjects: &visitedObjects
                )
            }
            currentMirror = activeMirror.superclassMirror
        }
    }
}

@_cdecl("BlueBubblesFindMyCopyDevicesSnapshot")
public func blueBubblesFindMyCopyDevicesSnapshot(
    _ dataSourcePointer: UnsafeMutableRawPointer?
) -> UnsafeMutableRawPointer? {
    guard let dataSourcePointer else {
        let response = ["error": "Find My Devices data source is unavailable"]
        return Unmanaged.passRetained(response as NSDictionary).toOpaque()
    }

    let dataSource = Unmanaged<AnyObject>.fromOpaque(dataSourcePointer).takeUnretainedValue()
    let response = FindMyDeviceSnapshot.response(from: dataSource)
    return Unmanaged.passRetained(response as NSDictionary).toOpaque()
}

@_cdecl("BlueBubblesFindMyCopyFMIPManager")
public func blueBubblesFindMyCopyFMIPManager(
    _ dataSourcePointer: UnsafeMutableRawPointer?
) -> UnsafeMutableRawPointer? {
    guard let dataSourcePointer else {
        return nil
    }

    let dataSource = Unmanaged<AnyObject>.fromOpaque(dataSourcePointer).takeUnretainedValue()
    guard let manager = FindMyDeviceSnapshot.fmipManager(from: dataSource) else {
        return nil
    }
    return Unmanaged.passRetained(manager).toOpaque()
}

@_cdecl("BlueBubblesFindMyCopyPeopleRowsMetadata")
public func blueBubblesFindMyCopyPeopleRowsMetadata(
    _ dataSourcePointer: UnsafeMutableRawPointer?
) -> UnsafeMutableRawPointer? {
    guard let dataSourcePointer else {
        return Unmanaged.passRetained(([:] as NSDictionary)).toOpaque()
    }

    let dataSource = Unmanaged<AnyObject>.fromOpaque(dataSourcePointer).takeUnretainedValue()
    let metadata = FindMyDeviceSnapshot.peopleRowsMetadata(from: dataSource)
    return Unmanaged.passRetained(metadata as NSDictionary).toOpaque()
}

@_cdecl("BlueBubblesFindMyCopyChildObject")
public func blueBubblesFindMyCopyChildObject(
    _ objectPointer: UnsafeMutableRawPointer?,
    _ childNamePointer: UnsafePointer<CChar>?
) -> UnsafeMutableRawPointer? {
    guard let objectPointer, let childNamePointer else {
        return nil
    }
    let object = Unmanaged<AnyObject>.fromOpaque(objectPointer).takeUnretainedValue()
    let childName = String(cString: childNamePointer)
    guard let childObject = FindMyDeviceSnapshot.childObject(named: childName, in: object) else {
        return nil
    }
    return Unmanaged.passRetained(childObject).toOpaque()
}

@_cdecl("BlueBubblesFindMyCopyFMFManager")
public func blueBubblesFindMyCopyFMFManager(
    _ containerPointer: UnsafeMutableRawPointer?
) -> UnsafeMutableRawPointer? {
    guard let containerPointer else {
        return nil
    }
    let container = Unmanaged<AnyObject>.fromOpaque(containerPointer).takeUnretainedValue()
    guard let manager = FindMyDeviceSnapshot.fmfManager(from: container) else {
        return nil
    }
    return Unmanaged.passRetained(manager).toOpaque()
}

public typealias BBFindMyFriendActionCallback = @convention(c) (
    UnsafeMutableRawPointer,
    UnsafeRawPointer,
    UnsafeMutableRawPointer?
) -> Void

@_cdecl("BlueBubblesFindMyWithMatchingFriend")
public func blueBubblesFindMyWithMatchingFriend(
    _ containerPointer: UnsafeMutableRawPointer?,
    _ targetsPointer: UnsafeMutableRawPointer?,
    _ callback: BBFindMyFriendActionCallback?,
    _ context: UnsafeMutableRawPointer?
) -> Bool {
    guard let containerPointer, let targetsPointer, let callback else {
        return false
    }
    let container = Unmanaged<AnyObject>.fromOpaque(containerPointer).takeUnretainedValue()
    guard let targets = Unmanaged<AnyObject>.fromOpaque(targetsPointer).takeUnretainedValue() as? [String] else {
        return false
    }
    return FindMyDeviceSnapshot.withMatchingFriend(in: container, targets: targets) { manager, friendPtr in
        let managerPtr = Unmanaged.passUnretained(manager).toOpaque()
        callback(managerPtr, friendPtr, context)
    }
}
