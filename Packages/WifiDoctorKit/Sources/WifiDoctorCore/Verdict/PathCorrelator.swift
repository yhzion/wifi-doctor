public enum PathCorrelator {
    public static func topology(wifi: HopList?, wired: HopList?) -> PathTopology {
        guard let wifi, let wired, let wifiFirst = wifi.hops.first, let wiredFirst = wired.hops.first else {
            return .unknown
        }
        if let address = wifiFirst.address, address == wiredFirst.address {
            return .sameFirstHop
        }
        for wifiHop in wifi.hops {
            guard let address = wifiHop.address else { continue }
            if let wiredHop = wired.hops.first(where: { $0.address == address }) {
                return .mergedLater(wifiIndex: wifiHop.index, wiredIndex: wiredHop.index)
            }
        }
        return .noMerge
    }
}
