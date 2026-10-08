# FS25 CP/AD Job Book

A job queue per vehicle for [Courseplay](https://github.com/Courseplay/Courseplay_FS25) and [AutoDrive](https://github.com/Stephan-S/FS25_AutoDrive). Private, singleplayer only. Tested against AutoDrive 3.0.1.4.

A job is a Courseplay course plus an AutoDrive destination (the field). When Courseplay finishes a course and more jobs are open, AutoDrive drives to the next field and Courseplay works the next course. When no job is open, AutoDrive parks the vehicle as usual.

## How it works

Starting a job:

1. The Courseplay course is loaded into the vehicle and the remembered waypoint is cleared, so the course starts at its beginning.
2. The field is put into the first AutoDrive marker (the "target", top row of the AutoDrive HUD). The AutoDrive mode is not changed. Supported modes are *pickup* (load), *drive to* and *deliver to*. In pickup mode the pickup place (second marker) and the fill type stay as set, so AutoDrive can refill during the Courseplay work and returns to the current field.
3. AutoDrive is started with the Courseplay helper switched on. When AutoDrive reaches the field it hands over to Courseplay on its own.

Finishing: `AutoDrive.onCpFinished` is wrapped. If a job is open, it is started shortly after instead of letting AutoDrive park the vehicle.

## Usage (console)

Sit in the vehicle (implement attached, AutoDrive mode set up as usual) and use:

| Command | Purpose |
|---|---|
| `jqCourses [words]` | Without words: folders with the number of courses. With words: matching courses. |
| `jqDest [words]` | Lists matching AutoDrive destinations. |
| `jqAdd <course words> \| <destination words>` | Adds a job, e.g. `jqAdd kalken F02 12m \| Feld 02`. Every word must be part of the name, an unclear match lists the candidates. |
| `jqList` | Shows the jobs of the vehicle. |
| `jqStart` | Starts the first job. |
| `jqStop` | Clears the queue and stops it (a running drive or course is not interrupted). |

## Build

`build.ps1` packs `FS25_CpAdJobBook/` into `FS25_CpAdJobBook.zip` in the mods folder (default `D:\GameData\FarmingSimulator2025\mods`). Close the game first, it locks the zip while running.

## Status

Version 0.1.3.0 works in the full workflow (hand-over to AutoDrive, next field, refilling during the work). The queue is kept in memory only and is lost when the savegame is reloaded. A menu is planned.
