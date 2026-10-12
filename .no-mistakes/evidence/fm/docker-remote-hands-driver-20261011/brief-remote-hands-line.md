# Generated ship briefs: the remote-hands routing line follows the lane state

## Lane ON (FM_REMOTE_HANDS=1 in the environment) — '# Local resources' section of data/brief-on/brief.md:

# Local resources
Before any memory-heavy command (a full build, test suite, lint walk, bundle, image build, or language-server index), take the machine's heavy slot: run `'/home/kirkins/.no-mistakes/worktrees/c3ea402bfbf7/01M4PSVQXR9F71QWA0A5SDFERG/bin/fm-heavy-slot.sh' acquire 'brief-on' --estimate <MB>` with your peak-RAM estimate in MB.
A refusal means another task holds the slot: append your standard `paused [at=<epoch>]:` wait naming the holder and stop; retry the acquire later, never run the job without the slot.
Run the job exactly under the cap wrapper the acquire output prints, and release the slot immediately after, as that output says.
When the remote-hands lane is on and the acquire is refused or the job class is too large for local memory, run `'/home/kirkins/.no-mistakes/worktrees/c3ea402bfbf7/01M4PSVQXR9F71QWA0A5SDFERG/bin/fm-remote-hands.sh' route --class <suite|sweep|other>` and follow its sandbox decision instead of waiting on the slot.

## Lane OFF (unconfigured home) — same section of data/brief-off/brief.md (no remote-hands line):

# Local resources
Before any memory-heavy command (a full build, test suite, lint walk, bundle, image build, or language-server index), take the machine's heavy slot: run `'/home/kirkins/.no-mistakes/worktrees/c3ea402bfbf7/01M4PSVQXR9F71QWA0A5SDFERG/bin/fm-heavy-slot.sh' acquire 'brief-off' --estimate <MB>` with your peak-RAM estimate in MB.
A refusal means another task holds the slot: append your standard `paused [at=<epoch>]:` wait naming the holder and stop; retry the acquire later, never run the job without the slot.
Run the job exactly under the cap wrapper the acquire output prints, and release the slot immediately after, as that output says.

## Scout scaffold with the lane ON via the home .env (data/brief-scout/brief.md, routing line):

When the remote-hands lane is on and the acquire is refused or the job class is too large for local memory, run `'/home/kirkins/.no-mistakes/worktrees/c3ea402bfbf7/01M4PSVQXR9F71QWA0A5SDFERG/bin/fm-remote-hands.sh' route --class <suite|sweep|other>` and follow its sandbox decision instead of waiting on the slot.
