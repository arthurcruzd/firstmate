// The one T3 thread -> status word rule, shared by the shell stream reader
// (t3code-eventwait.cjs) and the HTTP probe in t3code.sh, whose status table
// maps each word to busy and agent state. Background work (a terminal job
// outliving its turn) is active work even while the session reads ready.
module.exports = (thread) => thread.archivedAt ? 'archived' :
  thread.backgroundLiveness ? 'running' :
  thread.session?.status === 'stopped' && thread.settledAt ? 'settled-stopped' :
  thread.session?.status || 'idle';
