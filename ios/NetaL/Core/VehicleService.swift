import Foundation
import CoreLocation

/// 车辆管理：列表、绑定、驻车坐标。
///
/// 文案佐证（APK 内明文）：
/// `没有绑定车辆`、`登录后管理车辆与车控`、`绑定车辆`、
/// `解析驻车地址`、`导航去驻车位置`、`无驻车坐标`
struct VehicleSummary: Codable, Identifiable, Equatable {
    var id: String            // 车辆 ID / VIN
    var name: String          // 车辆昵称
    var model: String?        // 车型（如 EP30）
    var plate: String?        // 车牌
    var parkedLatitude: Double?
    var parkedLongitude: Double?
    var parkedAddress: String?
}

/// 车辆服务。
///
/// ⚠️ 所有端点均为推断，需抓包替换。
struct VehicleService {

    private let api: NetaAPIClient

    init(api: NetaAPIClient = NetaAPIClient()) {
        self.api = api
    }

    /// 车辆列表。
    func listVehicles() async throws -> [VehicleSummary] {
        try await AuthService.shared.ensureValidSession()

        let response = try await api.post(
            path: Endpoint.vehicleList,
            parameters: [:]
        )

        guard response.isSuccess else {
            throw VehicleError.serverRejected(response.message ?? "")
        }

        guard let payload = response.data?.asDictionary,
              let rawList = payload["list"]?.asArray ?? payload["vehicles"]?.asArray
        else {
            return []
        }

        return rawList.compactMap { item in
            guard case .object(let dict) = item else { return nil }
            // 兼容多种字段命名
            return VehicleSummary(
                id: dict["vehicleId"]?.asString ?? dict["id"]?.asString ?? "",
                name: dict["name"]?.asString ?? dict["nickName"]?.asString ?? "我的车",
                model: dict["model"]?.asString ?? dict["vehicleModel"]?.asString,
                plate: dict["plate"]?.asString ?? dict["licensePlate"]?.asString,
                parkedLatitude: dict["latitude"]?.asDouble ?? dict["lat"]?.asDouble,
                parkedLongitude: dict["longitude"]?.asDouble ?? dict["lng"]?.asDouble,
                parkedAddress: dict["address"]?.asString
            )
        }.filter { !$0.id.isEmpty }
    }

    /// 绑定车辆。
    func bind(vehicleId: String, nickname: String) async throws {
        try await AuthService.shared.ensureValidSession()

        let response = try await api.post(
            path: Endpoint.bindVehicle,
            parameters: ["vehicle_id": vehicleId, "nickname": nickname]
        )

        guard response.isSuccess else {
            throw VehicleError.bindFailed(response.message ?? "")
        }
    }

    /// 解绑车辆。
    func unbind(vehicleId: String) async throws {
        try await AuthService.shared.ensureValidSession()

        let response = try await api.post(
            path: Endpoint.unbindVehicle,
            parameters: ["vehicle_id": vehicleId]
        )

        guard response.isSuccess else {
            throw VehicleError.bindFailed(response.message ?? "")
        }
    }

    /// 当前主车辆。未绑定时抛 `notBound`（对应文案「没有绑定车辆」）。
    func primaryVehicle() async throws -> VehicleSummary {
        let vehicles = try await listVehicles()
        guard let first = vehicles.first else { throw VehicleError.notBound }
        return first
    }

    /// 驻车坐标。用于地理围栏靠近解锁。
    func parkingCoordinate() async throws -> CLLocationCoordinate2D {
        let vehicle = try await primaryVehicle()

        guard let lat = vehicle.parkedLatitude,
              let lon = vehicle.parkedLongitude else {
            throw VehicleError.noParkingCoordinate
        }

        return CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }
}

enum VehicleError: Error, LocalizedError {
    case notBound
    case noParkingCoordinate
    case bindFailed(String)
    case serverRejected(String)

    var errorDescription: String? {
        switch self {
        case .notBound:            return "没有绑定车辆"
        case .noParkingCoordinate: return "无驻车坐标"
        case .bindFailed(let m):   return m.isEmpty ? "绑定车辆失败" : m
        case .serverRejected(let m): return m.isEmpty ? "请求失败" : m
        }
    }
}

// MARK: - 辅助

extension JSONValue {
    var asDouble: Double? {
        if case .number(let d) = self { return d }
        if case .string(let s) = self { return Double(s) }
        return nil
    }

    var asArray: [JSONValue]? {
        if case .array(let a) = self { return a }
        return nil
    }
}

extension Endpoint {
    static let vehicleList = "/api/vehicle/list"
    static let bindVehicle = "/api/vehicle/bind"
    static let unbindVehicle = "/api/vehicle/unbind"
}