import CompanionDatabase
import Foundation
import Logging

struct ReminderDeliveryResult: Sendable {
  let botchillDelivered: Bool
  let pushDelivered: Bool
}

/// Polls due reminder jobs and delivers via Botchill voice and APNs.
actor ReminderWorker {
  private let reminders: ReminderRepository
  private let config: ConfigRepository
  private let pushDevices: PushDeviceRepository
  private let sessionRegistry: ActiveVoiceSessionRegistry
  private let apns: (any APNsSending)?
  private let logger: Logger
  private let pollInterval: Duration
  private var runTask: Task<Void, Never>?

  init(
    reminders: ReminderRepository,
    config: ConfigRepository,
    pushDevices: PushDeviceRepository,
    sessionRegistry: ActiveVoiceSessionRegistry,
    apns: (any APNsSending)?,
    logger: Logger,
    pollInterval: Duration = .seconds(10)
  ) {
    self.reminders = reminders
    self.config = config
    self.pushDevices = pushDevices
    self.sessionRegistry = sessionRegistry
    self.apns = apns
    self.logger = logger
    self.pollInterval = pollInterval
  }

  func start() {
    guard runTask == nil else { return }
    runTask = Task { [weak self] in
      await self?.runLoop()
    }
    logger.info("reminder worker started")
  }

  func stop() {
    runTask?.cancel()
    runTask = nil
    logger.info("reminder worker stopped")
  }

  private func runLoop() async {
    while !Task.isCancelled {
      await processDueJobs()
      do {
        try await Task.sleep(for: pollInterval)
      } catch {
        break
      }
    }
  }

  func processDueJobs() async {
    do {
      let jobs = try await reminders.claimDueJobs()
      guard !jobs.isEmpty else { return }
      logger.info(
        "reminder jobs due",
        metadata: ["count": .stringConvertible(jobs.count)]
      )
      let settings = try await config.get()
      for job in jobs {
        await deliver(job: job, settings: settings)
      }
    } catch {
      logger.warning("reminder worker tick failed", metadata: ["error": .string("\(error)")])
    }
  }

  private func deliver(job: ReminderJobRecord, settings: ConfigRecord) async {
    logger.info(
      "reminder delivering",
      metadata: Self.jobMetadata(job, remindBeforeMinutes: settings.remindBeforeMinutes)
    )

    let enabled: Bool
    switch job.kind {
    case .task:
      enabled = settings.taskReminders
    case .event:
      enabled = settings.calendarAlerts
    }

    guard enabled else {
      do {
        try await reminders.markSkipped(id: job.id, reason: "notifications_disabled")
        logger.info(
          "reminder skipped — notifications disabled",
          metadata: Self.jobMetadata(job, remindBeforeMinutes: settings.remindBeforeMinutes)
        )
      } catch {
        logger.warning("failed to mark reminder skipped", metadata: ["job_id": .string(job.id)])
      }
      return
    }

    var botchillDelivered = false
    var pushDelivered = false

    if let active = await sessionRegistry.currentSession() {
      botchillDelivered = await active.session.deliverReminder(
        job: job,
        gateway: active.gateway,
        remindBeforeMinutes: settings.remindBeforeMinutes
      )
      if !botchillDelivered {
        logger.info("reminder botchill unavailable", metadata: ["job_id": .string(job.id)])
      }
    } else {
      logger.info("reminder esp unavailable", metadata: ["job_id": .string(job.id)])
    }

    if let apns {
      do {
        let devices = try await pushDevices.list()
        if devices.isEmpty {
          logger.info("reminder push unavailable — no devices", metadata: ["job_id": .string(job.id)])
        } else {
          for device in devices {
            do {
              try await apns.sendReminder(
                to: device,
                job: job,
                remindBeforeMinutes: settings.remindBeforeMinutes
              )
              pushDelivered = true
              logger.info(
                "reminder push sent",
                metadata: Self.jobMetadata(job, remindBeforeMinutes: settings.remindBeforeMinutes)
                  .merging(["device_id": .string(device.id)], uniquingKeysWith: { _, new in new })
              )
            } catch {
              logger.warning(
                "apns send failed",
                metadata: [
                  "job_id": .string(job.id),
                  "device_id": .string(device.id),
                  "error": .string("\(error)"),
                ]
              )
            }
          }
        }
      } catch {
        logger.warning(
          "reminder push listing failed",
          metadata: ["job_id": .string(job.id), "error": .string("\(error)")]
        )
      }
    } else {
      logger.info("reminder push unavailable — apns not configured", metadata: ["job_id": .string(job.id)])
    }

    do {
      try await reminders.markFired(id: job.id)
      logger.info(
        "reminder fired",
        metadata: Self.jobMetadata(job, remindBeforeMinutes: settings.remindBeforeMinutes)
          .merging(
            [
              "botchill": .string("\(botchillDelivered)"),
              "push": .string("\(pushDelivered)"),
            ],
            uniquingKeysWith: { _, new in new }
          )
      )
    } catch {
      logger.warning(
        "failed to mark reminder fired",
        metadata: ["job_id": .string(job.id), "error": .string("\(error)")]
      )
    }
  }

  private static func jobMetadata(
    _ job: ReminderJobRecord,
    remindBeforeMinutes: Int
  ) -> Logger.Metadata {
    [
      "job_id": .string(job.id),
      "kind": .string(job.kind.rawValue),
      "source_id": .string(job.sourceId),
      "title": .string(job.title),
      "fire_at": .string(iso8601(job.fireAt)),
      "target_at": .string(iso8601(job.targetAt)),
      "remind_before_minutes": .stringConvertible(remindBeforeMinutes),
    ]
  }

  private static func iso8601(_ date: Date) -> String {
    ISO8601DateFormatter().string(from: date)
  }
}
