import Foundation

/// A typed activity event in durable commit order.
public struct ActivityEntry<Event: Codable & Sendable>: Codable, Sendable, Identifiable {
  /// The stable identity assigned when the event is committed.
  public let id: UUID
  /// The increasing commit sequence, independent of the event's occurrence time.
  public let sequence: UInt64
  /// The caller-supplied occurrence time.
  public let occurredAt: Date
  /// The caller-defined structured event, without rendered log text.
  public let event: Event
}
