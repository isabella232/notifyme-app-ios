//
/*
 * Copyright (c) 2020 Ubique Innovation AG <https://www.ubique.ch>
 *
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * SPDX-License-Identifier: MPL-2.0
 */

import CrowdNotifierSDK
import Foundation
import SwiftProtobuf

class ProblematicEventsManager {
    private let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.dateFormat = "E, dd MMM YYYY HH:mm:ss zzz"
        return formatter
    }()

    // MARK: - Shared

    public static let shared = ProblematicEventsManager()

    private let backend = Environment.current.backendService

    @UBOptionalUserDefault(key: "ch.notify-me.exposure.lastSync")
    private var lastSync: Int?

    @UBUserDefault(key: "ch.notify-me.exposure.notifiedIds", defaultValue: [])
    private(set) var notifiedIds: [String]

    private var exposureEvents: [ExposureEvent] {
        didSet { UIStateManager.shared.stateChanged() }
    }

    // MARK: - API

    public func getExposureEvents() -> [ExposureEvent] {
        return exposureEvents
    }

    public func sync(isBackgroundFetch: Bool = false, completion: @escaping (_ newData: Bool, _ needsNotification: Bool) -> Void) {
        var queryParameters = [String: String]()
        if let sync = lastSync {
            queryParameters["lastSync"] = "\(sync)"
        }

        let endpoint = backend.endpoint("traceKeys", queryParameters: queryParameters, headers: ["Accept": "application/protobuf"])

        let task = URLSession.shared.dataTask(with: endpoint.request()) { [weak self] data, response, _ in
            guard let strongSelf = self else {
                completion(false, false)
                return
            }

            if let dateHeader = (response as? HTTPURLResponse)?.allHeaderFields["Date"] as? String, let date = strongSelf.dateFormatter.date(from: dateHeader) {
                strongSelf.lastSync = date.millisecondsSince1970
            }

            let block = {
                if let data = data {
                    let wrapper = try? ProblematicEventWrapper(serializedData: data)
                    strongSelf.checkForMatches(wrapper: wrapper)

                    // Only if there is a checkin id that has not trigered a notification yet,
                    // a notification needs to be triggered
                    let newCheckinIds = strongSelf.exposureEvents.map { $0.checkinId }.filter { !strongSelf.notifiedIds.contains($0) }
                    strongSelf.notifiedIds.append(contentsOf: newCheckinIds)
                    let needsNewNotification = !newCheckinIds.isEmpty
                    completion(true, needsNewNotification)
                } else {
                    completion(false, false)
                }
            }

            if isBackgroundFetch {
                block()
            } else {
                DispatchQueue.main.async(execute: block)
            }
        }

        task.resume()
    }

    // MARK: - Init

    private init() {
        exposureEvents = CrowdNotifier.getExposureEvents()
    }

    // MARK: - Check

    private func checkForMatches(wrapper: ProblematicEventWrapper?) {
        guard let wrapper = wrapper else { return }

        var problematicEvents: [ProblematicEventInfo] = []

        for i in wrapper.events {
            let sk = i.secretKey.bytes
            let entry: Date = Date(timeIntervalSince1970: TimeInterval(i.startTime / 1000))
            let exit: Date = Date(timeIntervalSince1970: TimeInterval(i.endTime / 1000))
            let message = i.message.bytes

            let info = ProblematicEventInfo(privateKey: sk, entry: entry, exit: exit, message: message)
            problematicEvents.append(info)
        }

        CrowdNotifier.cleanUpOldData(maxDaysToKeep: 14)
        exposureEvents = CrowdNotifier.checkForMatches(publishedSKs: problematicEvents)
    }
}