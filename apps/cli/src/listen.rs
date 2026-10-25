//! The server's one network file: it accepts connections and opens none.
//!
//! `scripts/check-network-surface.sh` allows sockets in this file only, and
//! forbids it to connect anywhere, so the promise is checked rather than
//! intended. Everything else in the server sees a connection as something
//! that reads, writes and can say whether the client has gone.

use std::io::{self, Read, Write};
use std::net::{Shutdown, TcpListener, TcpStream};
use std::time::Duration;

pub struct Listener {
    inner: TcpListener,
}

impl Listener {
    /// Listen on `address`, such as `127.0.0.1:8080`.
    pub fn bind(address: &str) -> io::Result<Listener> {
        let inner = TcpListener::bind(address)?;
        // non-blocking so the accepting thread can notice it should stop
        inner.set_nonblocking(true)?;
        Ok(Listener { inner })
    }

    /// The address actually bound, as text.
    pub fn address(&self) -> String {
        self.inner
            .local_addr()
            .map(|address| address.to_string())
            .unwrap_or_default()
    }

    /// The next connection, or `None` when none arrived within `wait`.
    pub fn accept(&self, wait: Duration) -> io::Result<Option<Conn>> {
        match self.inner.accept() {
            Ok((stream, _)) => {
                // BSD hands the listener's non-blocking flag to the new socket
                stream.set_nonblocking(false)?;
                stream.set_nodelay(true)?;
                Ok(Some(Conn { stream }))
            }
            Err(error) if error.kind() == io::ErrorKind::WouldBlock => {
                std::thread::sleep(wait);
                Ok(None)
            }
            Err(error) => Err(error),
        }
    }
}

/// One client connection.
pub struct Conn {
    stream: TcpStream,
}

impl Conn {
    /// Whether the client has closed the connection or reset it. Looks
    /// without waiting and without consuming anything.
    pub fn hung_up(&self) -> bool {
        if self.stream.set_nonblocking(true).is_err() {
            return true;
        }
        let gone = match self.stream.peek(&mut [0u8; 1]) {
            Ok(0) => true,
            Ok(_) => false,
            Err(error) => !matches!(
                error.kind(),
                io::ErrorKind::WouldBlock | io::ErrorKind::Interrupted
            ),
        };
        gone || self.stream.set_nonblocking(false).is_err()
    }

    pub fn set_read_timeout(&self, timeout: Option<Duration>) -> io::Result<()> {
        self.stream.set_read_timeout(timeout)
    }

    pub fn set_write_timeout(&self, timeout: Option<Duration>) -> io::Result<()> {
        self.stream.set_write_timeout(timeout)
    }

    /// Say the response is complete while still reading what the client
    /// sends, so closing does not reset the connection under the response.
    pub fn shutdown_write(&self) {
        let _ = self.stream.shutdown(Shutdown::Write);
    }
}

impl Read for Conn {
    fn read(&mut self, buffer: &mut [u8]) -> io::Result<usize> {
        self.stream.read(buffer)
    }
}

impl Write for Conn {
    fn write(&mut self, bytes: &[u8]) -> io::Result<usize> {
        self.stream.write(bytes)
    }

    fn flush(&mut self) -> io::Result<()> {
        self.stream.flush()
    }
}
