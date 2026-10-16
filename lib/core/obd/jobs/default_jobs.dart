import '../pid_constants.dart';
import 'job_definition.dart';

/// The jobs every installation starts with: one per PID the app can decode.
///
/// Periods follow how fast each quantity changes: engine speed, vehicle speed
/// and throttle every 500 ms, load every 2 s, temperatures and fuel level
/// every 10 s, slow-moving values every 60 s. Only the seven PIDs the app
/// normally shows are switched on; the rest are defined but off until a screen
/// or a diagnostic test asks for them.
const defaultJobs = <JobDefinition>[
  // Fast: 500 ms, priority 2.
  JobDefinition(pid: PidConstants.rpm, periodMs: 500, priority: 2),
  JobDefinition(pid: PidConstants.speed, periodMs: 500, priority: 2),
  JobDefinition(pid: PidConstants.throttlePos, periodMs: 500, priority: 2),

  // Medium: 2 s, priority 1.
  JobDefinition(pid: PidConstants.engineLoad, periodMs: 2000, priority: 1),
  JobDefinition(
      pid: PidConstants.map, periodMs: 2000, priority: 1, enabled: false),
  JobDefinition(
      pid: PidConstants.maf, periodMs: 2000, priority: 1, enabled: false),
  JobDefinition(
      pid: PidConstants.stftB1, periodMs: 2000, priority: 1, enabled: false),
  JobDefinition(
      pid: PidConstants.stftB2, periodMs: 2000, priority: 1, enabled: false),
  JobDefinition(
      pid: PidConstants.o2B1S1, periodMs: 2000, priority: 1, enabled: false),
  JobDefinition(
      pid: PidConstants.o2B1S2, periodMs: 2000, priority: 1, enabled: false),

  // Slow: 10 s, priority 0.
  JobDefinition(pid: PidConstants.coolantTemp, periodMs: 10000),
  JobDefinition(pid: PidConstants.intakeAirTemp, periodMs: 10000),
  JobDefinition(pid: PidConstants.fuelLevel, periodMs: 10000),
  JobDefinition(pid: PidConstants.oilTemp, periodMs: 10000, enabled: false),
  JobDefinition(pid: PidConstants.ltftB1, periodMs: 10000, enabled: false),
  JobDefinition(pid: PidConstants.ltftB2, periodMs: 10000, enabled: false),
  JobDefinition(
      pid: PidConstants.fuelPressure, periodMs: 10000, enabled: false),
  JobDefinition(
      pid: PidConstants.egrCommanded, periodMs: 10000, enabled: false),

  // Very slow: 60 s, priority 0.
  JobDefinition(
      pid: PidConstants.baroPressure, periodMs: 60000, enabled: false),
  JobDefinition(
      pid: PidConstants.engineRunTime, periodMs: 60000, enabled: false),
  JobDefinition(
      pid: PidConstants.distanceMilOn, periodMs: 60000, enabled: false),
];
