//! Starting the server when its socket is missing, against a fake server
//! the launcher brings up in-process.

mod support;

use std::io;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::sync::atomic::{AtomicU32, Ordering};
use std::time::Duration;

use sadl::autostart::{StartError, connect_or_start, sadld_command, spawn_detached};
use sadl::connection::ConnectError;
use support::Peer;
use tokio::net::UnixListener;
use tokio::time::timeout;

const WAIT: Duration = Duration::from_secs(5);

async fn within<T>(future: impl Future<Output = T>) -> T {
    timeout(Duration::from_secs(10), future)
        .await
        .expect("timed out")
}

/// A fake server on `path` that accepts every handshake.
fn serve(path: &Path) {
    let listener = UnixListener::bind(path).unwrap();
    tokio::spawn(async move {
        loop {
            let (stream, _) = listener.accept().await.unwrap();
            tokio::spawn(async move {
                let mut peer = Peer::new(stream);
                peer.accept_handshake().await;
                peer.read_line().await;
            });
        }
    });
}

/// A launcher that counts its calls and starts a fake server on `path`.
fn counting_launcher(path: PathBuf) -> (Arc<AtomicU32>, impl FnMut() -> io::Result<()>) {
    let launches = Arc::new(AtomicU32::new(0));
    let counter = launches.clone();
    let launch = move || {
        counter.fetch_add(1, Ordering::SeqCst);
        serve(&path);
        Ok(())
    };
    (launches, launch)
}

#[tokio::test]
async fn connects_without_launching_when_the_server_is_up() {
    let path = support::socket_path();
    serve(&path);

    let result = within(connect_or_start(&path, WAIT, || {
        panic!("launched a running server")
    }))
    .await;

    assert!(result.is_ok(), "{result:?}");
}

#[tokio::test]
async fn launches_the_server_when_the_socket_is_missing() {
    let path = support::socket_path();
    let (launches, launch) = counting_launcher(path.clone());

    let result = within(connect_or_start(&path, WAIT, launch)).await;

    assert!(result.is_ok(), "{result:?}");
    assert_eq!(launches.load(Ordering::SeqCst), 1);
}

#[tokio::test]
async fn launches_the_server_when_the_socket_is_stale() {
    let path = support::socket_path();
    drop(UnixListener::bind(&path).unwrap());
    assert!(path.exists());
    let (launches, mut launch) = counting_launcher(path.clone());
    let stale = path.clone();

    let result = within(connect_or_start(&path, WAIT, move || {
        std::fs::remove_file(&stale)?;
        launch()
    }))
    .await;

    assert!(result.is_ok(), "{result:?}");
    assert_eq!(launches.load(Ordering::SeqCst), 1);
}

#[tokio::test]
async fn launches_the_server_into_a_missing_socket_directory() {
    let dir = support::socket_path().with_extension("d");
    let path = dir.join("sadld.sock");
    let (launches, launch) = counting_launcher(path.clone());

    let result = within(connect_or_start(&path, WAIT, launch)).await;

    assert!(result.is_ok(), "{result:?}");
    assert_eq!(launches.load(Ordering::SeqCst), 1);
    std::fs::remove_dir_all(dir).unwrap();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn ten_clients_starting_at_once_launch_one_server() {
    let path = support::socket_path();
    let launches = Arc::new(AtomicU32::new(0));

    let clients: Vec<_> = (0..10)
        .map(|_| {
            let path = path.clone();
            let launches = launches.clone();
            tokio::spawn(async move {
                connect_or_start(&path, WAIT, || {
                    launches.fetch_add(1, Ordering::SeqCst);
                    // A server that takes a while to bind its socket.
                    let path = path.clone();
                    tokio::spawn(async move {
                        tokio::time::sleep(Duration::from_millis(100)).await;
                        serve(&path);
                    });
                    Ok(())
                })
                .await
            })
        })
        .collect();

    for client in clients {
        let result = within(client).await.unwrap();
        assert!(result.is_ok(), "{result:?}");
    }
    assert_eq!(launches.load(Ordering::SeqCst), 1);
}

#[tokio::test]
async fn times_out_when_the_launched_server_never_listens() {
    let path = support::socket_path();

    let result = within(connect_or_start(&path, Duration::from_millis(200), || {
        Ok(())
    }))
    .await;

    assert!(matches!(result, Err(StartError::Timeout(_))), "{result:?}");
}

#[tokio::test]
async fn reports_a_launch_that_fails() {
    let path = support::socket_path();

    let result = within(connect_or_start(&path, WAIT, || {
        Err(io::Error::from(io::ErrorKind::NotFound))
    }))
    .await;

    assert!(matches!(result, Err(StartError::Launch(_))), "{result:?}");
}

#[tokio::test]
async fn does_not_launch_when_the_server_rejects_the_handshake() {
    let path = support::socket_path();
    let listener = UnixListener::bind(&path).unwrap();
    tokio::spawn(async move {
        let mut peer = Peer::new(listener.accept().await.unwrap().0);
        peer.read_line().await;
        peer.write(include_str!(
            "../../protocol/fixtures/handshake.response.version-mismatch.json"
        ))
        .await;
        peer.write("\n").await;
        peer.read_line().await;
    });

    let result = within(connect_or_start(&path, WAIT, || {
        panic!("launched past a rejection")
    }))
    .await;

    assert!(
        matches!(
            result,
            Err(StartError::Connect(ConnectError::Rejected(ref error))) if error.code == -32000
        ),
        "{result:?}"
    );
}

#[test]
fn sadld_command_starts_the_release_in_the_foreground() {
    let command = sadld_command();

    let args: Vec<_> = command.get_args().collect();
    assert_eq!(args, ["start"]);
}

#[tokio::test]
async fn spawn_detached_puts_the_server_in_its_own_process_group() {
    let out = support::socket_path().with_extension("pgrp");
    let mut command = std::process::Command::new("sh");
    command.arg("-c").arg(format!(
        "read -r pid _ _ _ pgrp _ < /proc/self/stat; echo \"$pid $pgrp\" > {}.tmp; mv {0}.tmp {0}",
        out.display()
    ));

    spawn_detached(command).unwrap();

    let written = within(async {
        loop {
            if let Ok(text) = std::fs::read_to_string(&out) {
                return text;
            }
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
    })
    .await;
    std::fs::remove_file(&out).unwrap();
    let (pid, pgrp) = written.trim().split_once(' ').unwrap();
    assert_eq!(pid, pgrp, "{written}");
}

#[tokio::test]
async fn spawn_detached_reports_a_missing_program() {
    let command = std::process::Command::new("/nonexistent/sadld");

    let error = spawn_detached(command).unwrap_err();

    assert_eq!(error.kind(), io::ErrorKind::NotFound);
}
