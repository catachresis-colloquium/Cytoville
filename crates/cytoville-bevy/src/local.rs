// SPDX-License-Identifier: AGPL-3.0-or-later
//! One in-flight offline transaction. The UI retains its acknowledged snapshot.
use super::performance;
use cytoville_core::Command;
use cytoville_runtime::Runtime;
use std::{
    path::PathBuf,
    sync::{Arc, Mutex},
    thread::JoinHandle,
    time::Instant,
};

// The outer main function keeps a clone after Bevy consumes the App. It drains
// the slot after App::run returns, including window-close paths.
#[derive(Clone, Default)]
pub struct Queue(Arc<Mutex<Option<Job>>>);
impl Queue {
    pub fn is_some(&self) -> bool {
        // A poisoned slot must never admit a second writer.
        self.0.lock().map_or(true, |slot| slot.is_some())
    }

    pub fn start(
        &self,
        runtime: Runtime,
        path: PathBuf,
        command: Option<Command>,
    ) -> Result<(), String> {
        self.submit(|| Job::start(runtime, path, command))
    }

    pub(super) fn submit(&self, start: impl FnOnce() -> Result<Job, String>) -> Result<(), String> {
        let mut slot = self
            .0
            .lock()
            .map_err(|_| "Local operation queue is unavailable")?;
        if slot.is_some() {
            return Err("Finishing the previous action and saving your progress…".into());
        }
        *slot = Some(start()?);
        Ok(())
    }

    pub fn poll(&self) -> Result<Option<Completed>, String> {
        let job = {
            let mut slot = self
                .0
                .lock()
                .map_err(|_| "Local operation queue is unavailable")?;
            if slot.as_ref().is_some_and(Job::is_finished) {
                slot.take()
            } else {
                None
            }
        };
        job.map(Job::finish).transpose()
    }

    pub fn finish(&self) -> Result<Option<Completed>, String> {
        let job = self
            .0
            .lock()
            .map_err(|_| "Local operation queue is unavailable")?
            .take();
        job.map(Job::finish).transpose()
    }
}

pub struct Completed {
    pub runtime: Runtime,
    pub manual_save: bool,
    pub travelled: bool,
}

pub struct Job {
    thread: JoinHandle<Result<Completed, String>>,
    submitted: Instant,
}

impl Job {
    pub fn start(
        runtime: Runtime,
        path: PathBuf,
        command: Option<Command>,
    ) -> Result<Self, String> {
        if path.with_extension("tmp") == path {
            return Err(
                "Choose a save filename ending in .json; .tmp is reserved for pending saves."
                    .into(),
            );
        }
        Self::spawn(move || {
            let _timing = performance::Span::new("command_and_autosave_ms");
            let mut runtime = runtime;
            let travelled = matches!(command, Some(Command::Travel { .. }));
            if let Some(command) = &command {
                let _timing = performance::Span::new("local_dispatch_ms");
                runtime.dispatch(0, command)?;
            }
            let bytes = {
                let _timing = performance::Span::new("save_serialize_ms");
                serde_json::to_vec(&runtime).map_err(|e| e.to_string())?
            };
            let temp = path.with_extension("tmp");
            {
                let _timing = performance::Span::new("save_write_ms");
                std::fs::write(&temp, bytes).map_err(|e| format!("Progress was not saved: {e}"))?;
            }
            {
                let _timing = performance::Span::new("save_replace_ms");
                std::fs::rename(&temp, &path)
                    .map_err(|e| format!("Progress was not saved: {e}"))?;
            }
            Ok(Completed {
                runtime,
                manual_save: command.is_none(),
                travelled,
            })
        })
    }

    pub(super) fn spawn(
        work: impl FnOnce() -> Result<Completed, String> + Send + 'static,
    ) -> Result<Self, String> {
        let submitted = Instant::now();
        let thread = std::thread::Builder::new()
            .name("cytoville-local".into())
            .spawn(work)
            .map_err(|e| format!("Cannot start local operation: {e}"))?;
        Ok(Self { thread, submitted })
    }

    pub fn is_finished(&self) -> bool {
        self.thread.is_finished()
    }

    // Called during normal updates only after is_finished, or at shutdown to
    // drain the one accepted request. Never detach a pending write on normal exit.
    pub fn finish(self) -> Result<Completed, String> {
        let result = self
            .thread
            .join()
            .map_err(|_| "Local operation stopped unexpectedly")?;
        performance::record(
            "local_completion_wait_ms",
            self.submitted.elapsed().as_secs_f64() * 1000.,
        );
        result
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use cytoville_core::Content;

    #[test]
    fn successful_job_matches_synchronous_dispatch_and_checkpoint() {
        let runtime = Runtime::new(
            Content::builtin(),
            "euglena",
            "full-cycle",
            "standard",
            7,
            false,
        )
        .unwrap();
        let mut expected = runtime.clone();
        expected.dispatch(0, &Command::EndTurn).unwrap();
        let path =
            std::env::temp_dir().join(format!("cytoville-worker-{}.json", std::process::id()));
        assert!(
            !path.exists(),
            "refuse to overwrite an existing test checkpoint"
        );
        let result = Job::start(runtime, path.clone(), Some(Command::EndTurn))
            .unwrap()
            .finish()
            .unwrap();
        let expected = serde_json::to_vec(&expected).unwrap();
        assert_eq!(serde_json::to_vec(&result.runtime).unwrap(), expected);
        assert_eq!(std::fs::read(&path).unwrap(), expected);
        std::fs::remove_file(path).unwrap();
    }

    #[test]
    fn failed_write_never_returns_an_acknowledged_state() {
        let runtime = Runtime::new(
            Content::builtin(),
            "euglena",
            "full-cycle",
            "standard",
            7,
            false,
        )
        .unwrap();
        // A regular file cannot be used as the parent of a checkpoint.
        let root =
            std::env::temp_dir().join(format!("cytoville-worker-file-{}.tmp", std::process::id()));
        let file = std::fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&root)
            .unwrap();
        drop(file);
        assert!(Job::start(runtime.clone(), root.clone(), Some(Command::EndTurn)).is_err());
        assert!(
            std::fs::read(&root).unwrap().is_empty(),
            "reserved temporary path was overwritten"
        );
        let result = Job::start(runtime, root.join("save.json"), Some(Command::EndTurn))
            .unwrap()
            .finish();
        assert!(matches!(result, Err(e) if e.contains("not saved")));
        std::fs::remove_file(root).unwrap();
    }

    #[test]
    fn outer_owner_drains_work_after_bevy_consumes_the_app() {
        #[derive(bevy::prelude::Resource)]
        struct Pending(Queue);
        let queue = Queue::default();
        let (release, wait) = std::sync::mpsc::channel();
        queue
            .submit(|| {
                Job::spawn(move || {
                    wait.recv().map_err(|e| e.to_string())?;
                    let runtime = Runtime::new(
                        Content::builtin(),
                        "euglena",
                        "full-cycle",
                        "standard",
                        7,
                        false,
                    )?;
                    Ok(Completed {
                        runtime,
                        manual_save: true,
                        travelled: false,
                    })
                })
            })
            .unwrap();
        let mut app = bevy::prelude::App::new();
        app.insert_resource(Pending(queue.clone()));
        app.set_runner(|app| {
            assert!(app.world().resource::<Pending>().0.is_some());
            bevy::app::AppExit::Success
        });
        app.run();
        assert!(queue.is_some());
        release.send(()).unwrap();
        assert!(queue.finish().unwrap().is_some());
        assert!(!queue.is_some());
    }
}
