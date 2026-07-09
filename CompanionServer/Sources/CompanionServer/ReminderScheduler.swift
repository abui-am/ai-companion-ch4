import CompanionDatabase
import Foundation
import Logging

/// Schedules or cancels reminder jobs when tasks/events change.
struct ReminderScheduler: Sendable {
  private let reminders: ReminderRepository
  private let config: ConfigRepository
  private let logger: Logger

  init(reminders: ReminderRepository, config: ConfigRepository, logger: Logger) {
    self.reminders = reminders
    self.config = config
    self.logger = logger
  }

  func scheduleTask(_ task: TaskRecord) async {
    do {
      let settings = try await config.get()
      if task.completed || task.dueAt == nil {
        try await reminders.cancel(kind: .task, sourceId: task.id)
        return
      }
      try await reminders.upsertTaskReminder(
        task: task,
        remindBeforeMinutes: settings.remindBeforeMinutes
      )
      if let dueAt = task.dueAt {
        let fireAt = dueAt.addingTimeInterval(-TimeInterval(settings.remindBeforeMinutes * 60))
        logger.info(
          "task reminder scheduled",
          metadata: [
            "task_id": .string(task.id),
            "title": .string(task.title),
            "due_at": .string(iso8601(dueAt)),
            "fire_at": .string(iso8601(fireAt)),
            "remind_before_minutes": .stringConvertible(settings.remindBeforeMinutes),
          ]
        )
      }
    } catch {
      logger.warning(
        "failed to schedule task reminder",
        metadata: ["task_id": .string(task.id), "error": .string("\(error)")]
      )
    }
  }

  func scheduleEvent(_ event: CalendarEventRecord) async {
    do {
      let settings = try await config.get()
      try await reminders.upsertEventReminder(
        event: event,
        remindBeforeMinutes: settings.remindBeforeMinutes
      )
      let fireAt = event.startsAt.addingTimeInterval(-TimeInterval(settings.remindBeforeMinutes * 60))
      logger.info(
        "event reminder scheduled",
        metadata: [
          "event_id": .string(event.id),
          "title": .string(event.title),
          "starts_at": .string(iso8601(event.startsAt)),
          "fire_at": .string(iso8601(fireAt)),
          "remind_before_minutes": .stringConvertible(settings.remindBeforeMinutes),
        ]
      )
    } catch {
      logger.warning(
        "failed to schedule event reminder",
        metadata: ["event_id": .string(event.id), "error": .string("\(error)")]
      )
    }
  }

  func cancelTask(id: String) async {
    do {
      try await reminders.cancel(kind: .task, sourceId: id)
    } catch {
      logger.warning(
        "failed to cancel task reminder",
        metadata: ["task_id": .string(id), "error": .string("\(error)")]
      )
    }
  }

  func cancelEvent(id: String) async {
    do {
      try await reminders.cancel(kind: .event, sourceId: id)
    } catch {
      logger.warning(
        "failed to cancel event reminder",
        metadata: ["event_id": .string(id), "error": .string("\(error)")]
      )
    }
  }

  func recomputeAfterConfigChange(previousMinutes: Int?, newMinutes: Int) async {
    guard previousMinutes != newMinutes else { return }
    do {
      try await reminders.recomputePendingFireTimes(remindBeforeMinutes: newMinutes)
      logger.info(
        "recomputed pending reminder fire times",
        metadata: ["remind_before_minutes": "\(newMinutes)"]
      )
    } catch {
      logger.warning(
        "failed to recompute reminder fire times",
        metadata: ["error": .string("\(error)")]
      )
    }
  }

  private func iso8601(_ date: Date) -> String {
    ISO8601DateFormatter().string(from: date)
  }
}
