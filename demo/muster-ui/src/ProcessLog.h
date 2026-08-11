#ifndef PROCESS_LOG_H
#define PROCESS_LOG_H

#include <QString>

// Everything Qt logs in this process, written to a run log of its own.
//
// Process-global, because a Qt message handler is. Installing one from a plugin
// is safe here and nowhere else: a view module gets its own host process and this
// plugin is the only thing in it.
//
// install() and openIn() are separate because the directory is not known until
// later in startup; lines are held in memory in between, capped, and flushed in
// order once there is somewhere to put them.
namespace ProcessLog {

// Installs the message handler, chaining to whatever was installed before it so
// nothing that used to reach stderr stops doing so. Idempotent.
void install();

// Opens this run's file under `directory` and writes everything buffered since
// install(). False when there is nowhere to write, which leaves the buffer to be
// discarded and path() empty.
bool openIn(const QString& directory);

// The file being written, empty until openIn() succeeds.
QString path();

} // namespace ProcessLog

#endif
