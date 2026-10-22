# FS25 CP/AD Job Book

A job queue per vehicle for [Courseplay](https://github.com/Courseplay/Courseplay_FS25) and [AutoDrive](https://github.com/Stephan-S/FS25_AutoDrive). Private, singleplayer only. Tested against AutoDrive 3.0.1.4.

A job is a Courseplay course plus an AutoDrive destination (the field). When Courseplay finishes a course and more jobs are open, AutoDrive drives to the next field and Courseplay works the next course. When no job is open, AutoDrive parks the vehicle as usual.

## How it works

Starting a job:

1. The Courseplay course is loaded into the vehicle and the remembered waypoint is cleared, so the course starts at its beginning. The Courseplay setting "start at" of the vehicle is set to "first waypoint", so a course started by hand afterwards also begins at the start.
2. The field is put into the first AutoDrive marker (the "target", top row of the AutoDrive HUD). The AutoDrive mode is not changed. Supported modes are *pickup* (load), *pickup and deliver*, *drive to* and *deliver to*. In pickup mode the pickup place (second marker) and the fill type stay as set, so AutoDrive can refill during the Courseplay work and returns to the current field. In pickup and deliver mode the field is the pickup place (first marker) and the unload place (second marker) stays as set: when Courseplay reports the vehicle full, AutoDrive unloads there and returns to the field. If a job can't be started (e.g. an unsupported mode), it stays at the front of the queue and the reason is shown in the window.
3. AutoDrive is started with the Courseplay helper switched on. When AutoDrive reaches the field it hands over to Courseplay on its own.

Finishing: `AutoDrive.onCpFinished` is wrapped. If a job is open, it is started shortly after instead of letting AutoDrive park the vehicle. When the last job is done, AutoDrive parks as usual and, a moment later (once Courseplay has stopped), the Courseplay course is removed from the vehicle, like the remove button in the Courseplay HUD. This only happens when the queue finishes, not when you stop it or a job can't be started.

## Usage (job book window)

Sit in the vehicle (implement attached, AutoDrive mode set up as usual) and press **Ctrl+J** (rebind it in the controls settings, action "Job book"). The window shows the jobs of the vehicle: the running one first ("now"), then the open jobs.

| Button | Purpose |
|---|---|
| Add | Opens a second window: courses of the Courseplay course manager on the left, AutoDrive destinations on the right, each with a text filter (every word must be part of the name). *Add* appends the selected pair as a job and stays open for more. |
| Status line (click) | Gives the queue of the vehicle a name (text input of the game), shown in the status line and written into the events. An empty text removes the name. The line lights up when the mouse is over it. |
| Remove, Up, Down | Change the selected open job. The running job can't be changed. |
| Start / Stop | Start: begins with the first open job and closes the window (if the vehicle can't start, the reason is shown instead). Stop: the queue doesn't continue after the current course, the open jobs are kept, a running drive or course is not interrupted. |

## Usage (console)

The console commands do the same without the window. With the vehicle set up as above, use:

| Command | Purpose |
|---|---|
| `jqCourses [words]` | Without words: folders with the number of courses. With words: matching courses. |
| `jqDest [words]` | Lists matching AutoDrive destinations. |
| `jqAdd <course words> \| <destination words>` | Adds a job, e.g. `jqAdd kalken F02 12m \| Feld 02`. Every word must be part of the name, an unclear match lists the candidates. |
| `jqList` | Shows the jobs of the vehicle. |
| `jqStart` | Starts the first job. |
| `jqStop` | Clears the queue and stops it (a running drive or course is not interrupted). Unlike *Stop* in the window, this also removes the open jobs. |
| `jqName <text>` | Names the queue of the vehicle (without text: removes the name). |

## Events file

When the queue of a vehicle is finished (the last course is done, no open job left) or stops because a job can't be started, the mod writes an event to `modSettings/FS25_CpAdJobBook/events.json` (the last 20 events, each with `id`, `time`, `type` (`queue_finished` / `queue_stopped`), `vehicle`, `queue` (the queue name) and `reason`). A game mod can't open network connections, so the mod only writes the file: any external program can watch it and forward the events (a message, a smart home notification, ...).

To try it without finishing a course, sit in a vehicle and enter `jqTestEvent` (a finished queue) or `jqTestEvent stopped` in the game console: it writes a test event.

## Build

`build.ps1` packs `FS25_CpAdJobBook/` into `FS25_CpAdJobBook.zip` in the mods folder (default `E:\GameData\FarmingSimulator2025\mods`). Close the game first, it locks the zip while running.

## Status

Version 0.2.0.0 works in the full workflow (hand-over to AutoDrive, next field, refilling during the work). The queues are saved with the savegame in `cpAdJobBook.xml` and are there again after loading. A queue that was running stays running: continue the Courseplay course by hand, and when it finishes the queue goes on with the next job (`jqStop` cancels). The AutoDrive destination is found again by its name if the marker ids change.

Version 0.3.0.0 adds the job book window. Adding, removing, moving, starting and stopping from the window are tested in the game. The course list is flat (filter by path), there is no folder tree yet.

Version 0.3.1.0 sets the Courseplay "start at" setting to "first waypoint" whenever a job is started.

Version 0.3.2.0 refreshes the job book window while it is open, so it follows the queue when a job starts or finishes.

Version 0.4.2.0 removes the Courseplay course from the vehicle when the queue is finished.

Version 0.5.0.0 adds names for the queues (window, `jqName`, savegame, field `queue` in the events file).

Version 0.6.0.0 shows what the vehicle does right now in the job book window: the AutoDrive task ("Drive to load point", ...) with the remaining drive time, or Courseplay with the waypoint and the remaining time of the course. Tested in the game, both the AutoDrive and the Courseplay line.
