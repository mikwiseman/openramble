//! Just enough HTTP/1.1 for one upload per connection.
//!
//! Every connection carries one request and is closed after its response, so
//! there is no keep-alive, pipelining or connection reuse to get wrong. The
//! request head is parsed by `httparse` and capped at 16 KiB; the body is
//! framed by Content-Length or chunked transfer coding and nothing else, and a
//! request that names both, or two lengths, is refused (a disagreement between
//! two parsers is how requests get smuggled past a proxy).
//!
//! The upload is streamed straight into a sink (the server's unnamed file)
//! through a fixed 64 KiB buffer, so a 1 GB meeting costs the same memory as a
//! voice note. A multipart body's `file` part is the audio and its other parts
//! are the parameters; any other body is the audio itself, with the
//! parameters in the query string. Everything here works on any `Read` and
//! `Write`, so it is tested without sockets.

use std::io::{self, Read, Write};

/// The largest request head: request line and headers.
pub const MAX_HEAD: usize = 16 * 1024;
/// The most bytes of non-file form fields, all together.
pub const MAX_FIELDS_BYTES: usize = 1024 * 1024;
/// The most parts a multipart body may have.
pub const MAX_PARTS: usize = 1000;
/// The largest headers of one multipart part.
pub const MAX_PART_HEAD: usize = 8 * 1024;
const BUFFER: usize = 64 * 1024;
const MAX_BOUNDARY: usize = 200;
const MAX_CHUNK_LINE: usize = 1024;
const MAX_TRAILERS: usize = 8 * 1024;

#[derive(Debug)]
pub enum HttpError {
    /// 400, with a fixed message.
    BadRequest(&'static str),
    /// 413: the upload passed its cap.
    TooLarge,
    /// The client closed the connection before sending a request.
    Closed,
    /// The connection failed or timed out; no response can be expected to
    /// arrive.
    Io(io::Error),
}

const MALFORMED_BODY: &str = "The request body is malformed.";

impl From<io::Error> for HttpError {
    fn from(error: io::Error) -> Self {
        match error.kind() {
            io::ErrorKind::InvalidData => HttpError::BadRequest(MALFORMED_BODY),
            _ => HttpError::Io(error),
        }
    }
}

fn malformed() -> io::Error {
    io::Error::new(io::ErrorKind::InvalidData, MALFORMED_BODY)
}

/// A reader with a fixed buffer that can be searched before it is consumed.
pub struct Input<R> {
    inner: R,
    buffer: Box<[u8]>,
    start: usize,
    end: usize,
}

impl<R: Read> Input<R> {
    pub fn new(inner: R) -> Self {
        Input {
            inner,
            buffer: vec![0; BUFFER].into_boxed_slice(),
            start: 0,
            end: 0,
        }
    }

    pub fn get_ref(&self) -> &R {
        &self.inner
    }

    pub fn get_mut(&mut self) -> &mut R {
        &mut self.inner
    }

    fn buffered(&self) -> &[u8] {
        &self.buffer[self.start..self.end]
    }

    fn consume(&mut self, count: usize) {
        self.start += count;
        debug_assert!(self.start <= self.end);
    }

    /// Read more into the buffer; `Ok(0)` at the end of the input.
    fn fill(&mut self) -> io::Result<usize> {
        if self.start > 0 {
            self.buffer.copy_within(self.start..self.end, 0);
            self.end -= self.start;
            self.start = 0;
        }
        if self.end == self.buffer.len() {
            return Err(malformed());
        }
        loop {
            match self.inner.read(&mut self.buffer[self.end..]) {
                Ok(read) => {
                    self.end += read;
                    return Ok(read);
                }
                Err(error) if error.kind() == io::ErrorKind::Interrupted => continue,
                Err(error) => return Err(error),
            }
        }
    }

    /// Fill until at least `count` bytes are buffered; false at the end.
    fn want(&mut self, count: usize) -> io::Result<bool> {
        while self.buffered().len() < count {
            if self.fill()? == 0 {
                return Ok(false);
            }
        }
        Ok(true)
    }
}

impl<R: Read> Read for Input<R> {
    fn read(&mut self, out: &mut [u8]) -> io::Result<usize> {
        if self.buffered().is_empty() && self.fill()? == 0 {
            return Ok(0);
        }
        let count = out.len().min(self.buffered().len());
        out[..count].copy_from_slice(&self.buffered()[..count]);
        self.consume(count);
        Ok(count)
    }
}

/// Where `pattern` first occurs in `haystack`.
fn find(haystack: &[u8], pattern: &[u8]) -> Option<usize> {
    let first = *pattern.first()?;
    let mut from = 0;
    while let Some(offset) = haystack[from..].iter().position(|&b| b == first) {
        let at = from + offset;
        if haystack.len() - at < pattern.len() {
            return None;
        }
        if haystack[at..].starts_with(pattern) {
            return Some(at);
        }
        from = at + 1;
    }
    None
}

/// How the body is delimited.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Framing {
    Empty,
    Length(u64),
    Chunked,
}

/// A parsed request head.
#[derive(Debug)]
pub struct Head {
    pub method: String,
    /// The path without its query string.
    pub path: String,
    /// The raw query string, without `?`.
    pub query: String,
    headers: Vec<(String, Vec<u8>)>,
    pub framing: Framing,
}

impl Head {
    /// The first header with this name (case-insensitive), as text.
    pub fn header(&self, name: &str) -> Option<&str> {
        self.headers
            .iter()
            .find(|(n, _)| n.eq_ignore_ascii_case(name))
            .and_then(|(_, value)| std::str::from_utf8(value).ok())
            .map(str::trim)
    }

    fn all<'a>(&'a self, name: &'a str) -> impl Iterator<Item = &'a [u8]> {
        self.headers
            .iter()
            .filter(move |(n, _)| n.eq_ignore_ascii_case(name))
            .map(|(_, value)| value.as_slice())
    }

    pub fn expects_continue(&self) -> bool {
        self.header("expect")
            .is_some_and(|value| value.eq_ignore_ascii_case("100-continue"))
    }

    /// The body's declared length, when it has one.
    pub fn content_length(&self) -> Option<u64> {
        match self.framing {
            Framing::Length(length) => Some(length),
            Framing::Empty => Some(0),
            Framing::Chunked => None,
        }
    }
}

/// Read and parse the request head, leaving the body unread.
pub fn read_head<R: Read>(input: &mut Input<R>) -> Result<Head, HttpError> {
    loop {
        let limit = input.buffered().len().min(MAX_HEAD + 4);
        if let Some(at) = find(&input.buffered()[..limit], b"\r\n\r\n") {
            let head = parse_head(&input.buffered()[..at + 4])?;
            input.consume(at + 4);
            return Ok(head);
        }
        if input.buffered().len() > MAX_HEAD {
            return Err(HttpError::BadRequest(
                "The request head is larger than 16 KiB.",
            ));
        }
        if input.fill()? == 0 {
            return Err(if input.buffered().is_empty() {
                HttpError::Closed
            } else {
                HttpError::BadRequest("The request head is incomplete.")
            });
        }
    }
}

fn parse_head(bytes: &[u8]) -> Result<Head, HttpError> {
    let mut headers = [httparse::EMPTY_HEADER; 64];
    let mut request = httparse::Request::new(&mut headers);
    match request.parse(bytes) {
        Ok(httparse::Status::Complete(_)) => {}
        _ => return Err(HttpError::BadRequest("The request head is malformed.")),
    }
    let method = request.method.unwrap_or_default().to_string();
    let target = request.path.unwrap_or_default();
    let (path, query) = target.split_once('?').unwrap_or((target, ""));
    let mut head = Head {
        method,
        path: path.to_string(),
        query: query.to_string(),
        headers: request
            .headers
            .iter()
            .map(|h| (h.name.to_ascii_lowercase(), h.value.to_vec()))
            .collect(),
        framing: Framing::Empty,
    };
    let codings: Vec<&[u8]> = head.all("transfer-encoding").collect();
    let lengths: Vec<&[u8]> = head.all("content-length").collect();
    head.framing = match (codings.as_slice(), lengths.as_slice()) {
        ([], []) => Framing::Empty,
        ([], [length]) => {
            let text = std::str::from_utf8(length).unwrap_or("").trim();
            if text.is_empty() || !text.bytes().all(|b| b.is_ascii_digit()) {
                return Err(HttpError::BadRequest("Content-Length is not a number."));
            }
            Framing::Length(
                text.parse()
                    .map_err(|_| HttpError::BadRequest("Content-Length is not a number."))?,
            )
        }
        ([], _) => return Err(HttpError::BadRequest("Content-Length is given twice.")),
        ([coding], []) if coding.trim_ascii().eq_ignore_ascii_case(b"chunked") => Framing::Chunked,
        (_, []) => {
            return Err(HttpError::BadRequest(
                "Transfer-Encoding must be chunked and nothing else.",
            ))
        }
        _ => {
            return Err(HttpError::BadRequest(
                "Content-Length and Transfer-Encoding cannot both be given.",
            ))
        }
    };
    Ok(head)
}

/// The request body, as its framing delimits it.
pub struct Body<'a, R> {
    input: &'a mut Input<R>,
    state: BodyState,
}

enum BodyState {
    Length(u64),
    /// Bytes left in the current chunk; `None` before a chunk-size line.
    Chunk(Option<u64>),
    Done,
}

impl<'a, R: Read> Body<'a, R> {
    pub fn new(input: &'a mut Input<R>, framing: Framing) -> Self {
        let state = match framing {
            Framing::Empty => BodyState::Done,
            Framing::Length(0) => BodyState::Done,
            Framing::Length(length) => BodyState::Length(length),
            Framing::Chunked => BodyState::Chunk(None),
        };
        Body { input, state }
    }

    /// One CRLF-terminated line, without its CRLF.
    fn line(&mut self, limit: usize) -> io::Result<Vec<u8>> {
        loop {
            let window = self.input.buffered().len().min(limit + 2);
            if let Some(at) = find(&self.input.buffered()[..window], b"\r\n") {
                let line = self.input.buffered()[..at].to_vec();
                self.input.consume(at + 2);
                return Ok(line);
            }
            if self.input.buffered().len() >= limit + 2 || self.input.fill()? == 0 {
                return Err(malformed());
            }
        }
    }

    fn next_chunk(&mut self) -> io::Result<u64> {
        let line = self.line(MAX_CHUNK_LINE)?;
        let size = line.split(|&b| b == b';').next().unwrap_or_default();
        let size = std::str::from_utf8(size).map_err(|_| malformed())?.trim();
        if size.is_empty() || size.len() > 15 {
            return Err(malformed());
        }
        let size = u64::from_str_radix(size, 16).map_err(|_| malformed())?;
        if size == 0 {
            // trailers, then the empty line that ends the body
            let mut total = 0;
            loop {
                let trailer = self.line(MAX_TRAILERS)?;
                total += trailer.len() + 2;
                if trailer.is_empty() {
                    break;
                }
                if total > MAX_TRAILERS {
                    return Err(malformed());
                }
            }
        }
        Ok(size)
    }
}

impl<R: Read> Read for Body<'_, R> {
    fn read(&mut self, out: &mut [u8]) -> io::Result<usize> {
        loop {
            match self.state {
                BodyState::Done => return Ok(0),
                BodyState::Length(remaining) => {
                    let wanted = out.len().min(remaining.min(usize::MAX as u64) as usize);
                    let read = self.input.read(&mut out[..wanted])?;
                    if read == 0 {
                        return Err(io::ErrorKind::UnexpectedEof.into());
                    }
                    let left = remaining - read as u64;
                    self.state = if left == 0 {
                        BodyState::Done
                    } else {
                        BodyState::Length(left)
                    };
                    return Ok(read);
                }
                BodyState::Chunk(None) => {
                    let size = self.next_chunk()?;
                    self.state = if size == 0 {
                        BodyState::Done
                    } else {
                        BodyState::Chunk(Some(size))
                    };
                }
                BodyState::Chunk(Some(remaining)) => {
                    let wanted = out.len().min(remaining.min(usize::MAX as u64) as usize);
                    let read = self.input.read(&mut out[..wanted])?;
                    if read == 0 {
                        return Err(io::ErrorKind::UnexpectedEof.into());
                    }
                    let left = remaining - read as u64;
                    if left == 0 {
                        if self.line(0)?.is_empty() {
                            self.state = BodyState::Chunk(None);
                        } else {
                            return Err(malformed());
                        }
                    } else {
                        self.state = BodyState::Chunk(Some(left));
                    }
                    return Ok(read);
                }
            }
        }
    }
}

/// Read and throw away the rest of a body, up to `limit` bytes; true when the
/// body ended within it.
pub fn discard(body: &mut impl Read, limit: u64) -> io::Result<bool> {
    let mut buffer = [0u8; 16 * 1024];
    let mut total = 0;
    loop {
        let read = body.read(&mut buffer)?;
        if read == 0 {
            return Ok(true);
        }
        total += read as u64;
        if total > limit {
            return Ok(false);
        }
    }
}

/// Copy everything from `from` to `sink`, refusing past `cap` bytes.
fn copy_capped(from: &mut impl Read, sink: &mut dyn Write, cap: u64) -> Result<u64, HttpError> {
    let mut buffer = vec![0u8; BUFFER];
    let mut total = 0u64;
    loop {
        let read = match from.read(&mut buffer) {
            Ok(0) => return Ok(total),
            Ok(read) => read,
            Err(error) if error.kind() == io::ErrorKind::Interrupted => continue,
            Err(error) => return Err(error.into()),
        };
        total += read as u64;
        if total > cap {
            return Err(HttpError::TooLarge);
        }
        sink.write_all(&buffer[..read]).map_err(HttpError::Io)?;
    }
}

/// The boundary of a `multipart/form-data` content type.
pub fn boundary(content_type: &str) -> Option<String> {
    let mut parts = content_type.split(';');
    let kind = parts.next()?.trim();
    if !kind.eq_ignore_ascii_case("multipart/form-data") {
        return None;
    }
    parts.find_map(|part| {
        let (name, value) = part.split_once('=')?;
        name.trim()
            .eq_ignore_ascii_case("boundary")
            .then(|| value.trim().trim_matches('"').to_string())
    })
}

/// The `name` of a part from its Content-Disposition.
fn part_name(headers: &[u8]) -> Option<String> {
    let text = std::str::from_utf8(headers).ok()?;
    let disposition = text.split("\r\n").find_map(|line| {
        let (name, value) = line.split_once(':')?;
        name.trim()
            .eq_ignore_ascii_case("content-disposition")
            .then_some(value)
    })?;
    disposition.split(';').skip(1).find_map(|parameter| {
        let (key, value) = parameter.split_once('=')?;
        (key.trim() == "name").then(|| value.trim().trim_matches('"').to_string())
    })
}

/// Stream until `pattern`, handing everything before it to `emit`; the
/// pattern itself is consumed.
fn until<R: Read>(
    input: &mut Input<R>,
    pattern: &[u8],
    emit: &mut dyn FnMut(&[u8]) -> Result<(), HttpError>,
) -> Result<(), HttpError> {
    loop {
        if let Some(at) = find(input.buffered(), pattern) {
            emit(&input.buffered()[..at])?;
            input.consume(at + pattern.len());
            return Ok(());
        }
        let safe = input.buffered().len().saturating_sub(pattern.len() - 1);
        emit(&input.buffered()[..safe])?;
        input.consume(safe);
        if input.fill()? == 0 {
            return Err(HttpError::BadRequest("The multipart body ended early."));
        }
    }
}

/// Stream a multipart body: the `file` part into `sink` (at most `cap`
/// bytes), the other parts returned as fields.
pub fn read_multipart(
    body: &mut impl Read,
    boundary: &str,
    sink: &mut dyn Write,
    cap: u64,
) -> Result<(Vec<(String, String)>, u64), HttpError> {
    if boundary.is_empty() || boundary.len() > MAX_BOUNDARY {
        return Err(HttpError::BadRequest(
            "The multipart boundary is not valid.",
        ));
    }
    let mut input = Input::new(body);
    let dash_boundary = format!("--{boundary}");
    let delimiter = format!("\r\n--{boundary}");
    // The first boundary usually opens the body; anything before it is a
    // preamble to skip.
    input.want(dash_boundary.len())?;
    if input.buffered().starts_with(dash_boundary.as_bytes()) {
        input.consume(dash_boundary.len());
    } else {
        let mut skipped = 0;
        until(&mut input, delimiter.as_bytes(), &mut |bytes| {
            skipped += bytes.len();
            if skipped > MAX_PART_HEAD {
                return Err(HttpError::BadRequest("The multipart body has no boundary."));
            }
            Ok(())
        })?;
    }
    let mut fields = Vec::new();
    let mut field_bytes = 0;
    let mut file_bytes = None;
    for _ in 0..=MAX_PARTS {
        // after a boundary: optional spaces, then "--" (the end) or CRLF
        loop {
            if !input.want(2)? {
                return Err(HttpError::BadRequest("The multipart body ended early."));
            }
            match input.buffered()[0] {
                b' ' | b'\t' => input.consume(1),
                _ => break,
            }
        }
        if input.buffered().starts_with(b"--") {
            input.consume(2);
            discard(&mut input, BUFFER as u64)?;
            let bytes = file_bytes.ok_or(HttpError::BadRequest("The file field is missing."))?;
            return Ok((fields, bytes));
        }
        if !input.buffered().starts_with(b"\r\n") {
            return Err(HttpError::BadRequest("The multipart body is malformed."));
        }
        input.consume(2);
        let mut headers = Vec::new();
        until(&mut input, b"\r\n\r\n", &mut |bytes| {
            headers.extend_from_slice(bytes);
            if headers.len() > MAX_PART_HEAD {
                return Err(HttpError::BadRequest(
                    "A multipart part's headers are too large.",
                ));
            }
            Ok(())
        })?;
        let name =
            part_name(&headers).ok_or(HttpError::BadRequest("A multipart part has no name."))?;
        if name == "file" {
            if file_bytes.is_some() {
                return Err(HttpError::BadRequest("Send one file per request."));
            }
            let mut written = 0u64;
            until(&mut input, delimiter.as_bytes(), &mut |bytes| {
                written += bytes.len() as u64;
                if written > cap {
                    return Err(HttpError::TooLarge);
                }
                sink.write_all(bytes).map_err(HttpError::Io)
            })?;
            file_bytes = Some(written);
        } else {
            let mut value = Vec::new();
            field_bytes += name.len();
            until(&mut input, delimiter.as_bytes(), &mut |bytes| {
                field_bytes += bytes.len();
                if field_bytes > MAX_FIELDS_BYTES {
                    return Err(HttpError::BadRequest(
                        "The form fields are larger than 1 MiB.",
                    ));
                }
                value.extend_from_slice(bytes);
                Ok(())
            })?;
            let value = String::from_utf8(value)
                .map_err(|_| HttpError::BadRequest("A form field is not UTF-8."))?;
            fields.push((name, value));
        }
    }
    Err(HttpError::BadRequest(
        "The multipart body has more than 1000 parts.",
    ))
}

/// Decode `application/x-www-form-urlencoded` text: `+` is a space and
/// `%XX` a byte.
pub fn percent_decode(text: &str) -> Result<String, HttpError> {
    let bytes = text.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut index = 0;
    while index < bytes.len() {
        match bytes[index] {
            b'+' => out.push(b' '),
            b'%' => {
                let hex = bytes
                    .get(index + 1..index + 3)
                    .and_then(|pair| std::str::from_utf8(pair).ok())
                    .and_then(|pair| u8::from_str_radix(pair, 16).ok())
                    .ok_or(HttpError::BadRequest("The query string is malformed."))?;
                out.push(hex);
                index += 2;
            }
            byte => out.push(byte),
        }
        index += 1;
    }
    String::from_utf8(out).map_err(|_| HttpError::BadRequest("The query string is not UTF-8."))
}

/// The query string's fields, in order.
pub fn query(raw: &str) -> Result<Vec<(String, String)>, HttpError> {
    raw.split('&')
        .filter(|pair| !pair.is_empty())
        .map(|pair| {
            let (name, value) = pair.split_once('=').unwrap_or((pair, ""));
            Ok((percent_decode(name)?, percent_decode(value)?))
        })
        .collect()
}

/// Read the body: the audio into `sink` (at most `cap` bytes) and the
/// parameters, query string first and form fields after, so a form field
/// wins over the same name in the query.
pub fn read_body<R: Read>(
    head: &Head,
    input: &mut Input<R>,
    sink: &mut dyn Write,
    cap: u64,
) -> Result<(Vec<(String, String)>, u64), HttpError> {
    let mut fields = query(&head.query)?;
    let mut body = Body::new(input, head.framing);
    let content_type = head.header("content-type").unwrap_or("");
    let multipart = content_type
        .split(';')
        .next()
        .is_some_and(|kind| kind.trim().eq_ignore_ascii_case("multipart/form-data"));
    let bytes = if multipart {
        let boundary = boundary(content_type)
            .ok_or(HttpError::BadRequest("The multipart boundary is missing."))?;
        let (form, bytes) = read_multipart(&mut body, &boundary, sink, cap)?;
        fields.extend(form);
        bytes
    } else {
        copy_capped(&mut body, sink, cap)?
    };
    Ok((fields, bytes))
}

fn reason(status: u16) -> &'static str {
    match status {
        100 => "Continue",
        200 => "OK",
        400 => "Bad Request",
        401 => "Unauthorized",
        404 => "Not Found",
        405 => "Method Not Allowed",
        413 => "Content Too Large",
        422 => "Unprocessable Content",
        429 => "Too Many Requests",
        500 => "Internal Server Error",
        503 => "Service Unavailable",
        _ => "Unknown",
    }
}

/// Tell a client that sent `Expect: 100-continue` to send its body.
pub fn write_continue(out: &mut impl Write) -> io::Result<()> {
    out.write_all(b"HTTP/1.1 100 Continue\r\n\r\n")?;
    out.flush()
}

/// A complete JSON response; the connection closes after it.
pub fn write_response(
    out: &mut impl Write,
    status: u16,
    extra: &[(&str, String)],
    body: &[u8],
) -> io::Result<()> {
    let mut head = format!(
        "HTTP/1.1 {status} {}\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n",
        reason(status),
        body.len()
    );
    for (name, value) in extra {
        head.push_str(&format!("{name}: {value}\r\n"));
    }
    head.push_str("\r\n");
    out.write_all(head.as_bytes())?;
    out.write_all(body)?;
    out.flush()
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Hands out its bytes `sizes` at a time, cycling.
    struct Dribble<R> {
        inner: R,
        sizes: Vec<usize>,
        turn: usize,
    }

    impl<R: Read> Read for Dribble<R> {
        fn read(&mut self, out: &mut [u8]) -> io::Result<usize> {
            let size = self.sizes[self.turn % self.sizes.len()].min(out.len());
            self.turn += 1;
            self.inner.read(&mut out[..size])
        }
    }

    fn dribble(bytes: &[u8], sizes: Vec<usize>) -> Dribble<&[u8]> {
        Dribble {
            inner: bytes,
            sizes,
            turn: 0,
        }
    }

    /// Bytes that look like a boundary as often as possible without being one.
    fn awkward(count: usize) -> Vec<u8> {
        let pattern = b"\r\n--Xb0undar\r\n-\r--Xb0und";
        (0..count)
            .map(|i| {
                if i % 97 < pattern.len() {
                    pattern[i % 97]
                } else {
                    (i * 31 % 251) as u8
                }
            })
            .collect()
    }

    fn form(boundary: &str, parts: &[(&str, &[u8])]) -> Vec<u8> {
        let mut body = Vec::new();
        for (name, value) in parts {
            body.extend_from_slice(format!("--{boundary}\r\n").as_bytes());
            let filename = if *name == "file" {
                "; filename=\"a.m4a\""
            } else {
                ""
            };
            body.extend_from_slice(
                format!("Content-Disposition: form-data; name=\"{name}\"{filename}\r\n\r\n")
                    .as_bytes(),
            );
            body.extend_from_slice(value);
            body.extend_from_slice(b"\r\n");
        }
        body.extend_from_slice(format!("--{boundary}--\r\n").as_bytes());
        body
    }

    fn request(head: &str, body: &[u8]) -> Vec<u8> {
        let mut bytes = head.replace('\n', "\r\n").into_bytes();
        bytes.extend_from_slice(body);
        bytes
    }

    #[test]
    fn a_boundary_split_across_any_read_size_is_found() {
        let boundary = "Xb0undary";
        let file = awkward(5_000);
        let body = form(
            boundary,
            &[
                ("model_id", b"scribe_v2"),
                ("file", &file),
                ("diarize", b"false"),
            ],
        );
        for size in 1..=17 {
            for sizes in [vec![size], vec![size, 1, size + 3]] {
                let mut sink = Vec::new();
                let (fields, bytes) = read_multipart(
                    &mut dribble(&body, sizes.clone()),
                    boundary,
                    &mut sink,
                    u64::MAX,
                )
                .unwrap();
                assert_eq!(sink, file, "reads of {sizes:?}");
                assert_eq!(bytes, file.len() as u64);
                assert_eq!(
                    fields,
                    [
                        ("model_id".into(), "scribe_v2".into()),
                        ("diarize".into(), "false".into())
                    ]
                );
            }
        }
    }

    /// A 50 MB upload is never held: the sink sees it in pieces no larger
    /// than the fixed buffer.
    #[test]
    fn a_large_upload_streams_through_a_fixed_buffer() {
        struct Generated {
            prefix: Vec<u8>,
            size: usize,
            suffix: Vec<u8>,
            at: usize,
        }
        impl Read for Generated {
            fn read(&mut self, out: &mut [u8]) -> io::Result<usize> {
                let total = self.prefix.len() + self.size + self.suffix.len();
                let count = out.len().min(total - self.at);
                for (i, slot) in out[..count].iter_mut().enumerate() {
                    let at = self.at + i;
                    *slot = if at < self.prefix.len() {
                        self.prefix[at]
                    } else if at < self.prefix.len() + self.size {
                        let i = at - self.prefix.len();
                        if i % 4093 < 6 {
                            b"\r\n--Xb"[i % 4093]
                        } else {
                            (i * 7 % 253) as u8
                        }
                    } else {
                        self.suffix[at - self.prefix.len() - self.size]
                    };
                }
                self.at += count;
                Ok(count)
            }
        }
        struct Check {
            total: usize,
            largest: usize,
            sum: u64,
        }
        impl Write for Check {
            fn write(&mut self, bytes: &[u8]) -> io::Result<usize> {
                self.largest = self.largest.max(bytes.len());
                for (i, &b) in bytes.iter().enumerate() {
                    self.sum = self
                        .sum
                        .wrapping_mul(31)
                        .wrapping_add(b as u64 ^ (self.total + i) as u64);
                }
                self.total += bytes.len();
                Ok(bytes.len())
            }
            fn flush(&mut self) -> io::Result<()> {
                Ok(())
            }
        }
        const SIZE: usize = 50 * 1024 * 1024;
        let mut generated = Generated {
            prefix: b"--Xb0undary\r\nContent-Disposition: form-data; name=\"file\"; filename=\"x\"\r\n\r\n"
                .to_vec(),
            size: SIZE,
            suffix: b"\r\n--Xb0undary--\r\n".to_vec(),
            at: 0,
        };
        let mut check = Check {
            total: 0,
            largest: 0,
            sum: 0,
        };
        let (_, bytes) = read_multipart(&mut generated, "Xb0undary", &mut check, u64::MAX).unwrap();
        assert_eq!((bytes as usize, check.total), (SIZE, SIZE));
        assert!(
            check.largest <= BUFFER,
            "a write of {} bytes",
            check.largest
        );
        let mut expected = Check {
            total: 0,
            largest: 0,
            sum: 0,
        };
        let content: Vec<u8> = (0..SIZE)
            .map(|i| {
                if i % 4093 < 6 {
                    b"\r\n--Xb"[i % 4093]
                } else {
                    (i * 7 % 253) as u8
                }
            })
            .collect();
        for piece in content.chunks(BUFFER) {
            expected.write_all(piece).unwrap();
        }
        assert_eq!(check.sum, expected.sum);
    }

    #[test]
    fn a_chunked_body_decodes_with_extensions_and_trailers() {
        let raw = request(
            "POST /v1/speech-to-text?timestamps_granularity=none HTTP/1.1\nHost: x\nTransfer-Encoding: chunked\n\n",
            b"5;ext=1\r\nhello\r\n1\r\n \r\nB\r\nworld again\r\n0\r\nX-Trailer: y\r\n\r\n",
        );
        for size in [1, 2, 3, 7, 64] {
            let mut input = Input::new(dribble(&raw, vec![size]));
            let head = read_head(&mut input).unwrap();
            assert_eq!(head.framing, Framing::Chunked);
            let mut sink = Vec::new();
            let (fields, bytes) = read_body(&head, &mut input, &mut sink, u64::MAX).unwrap();
            assert_eq!(sink, b"hello world again");
            assert_eq!(bytes, 17);
            assert_eq!(fields, [("timestamps_granularity".into(), "none".into())]);
        }
        for broken in [
            &b"zz\r\nhello\r\n0\r\n\r\n"[..],
            b"5\r\nhelloXX0\r\n\r\n",
            b"5\r\nhel",
        ] {
            let raw = request("POST / HTTP/1.1\nTransfer-Encoding: chunked\n\n", broken);
            let mut input = Input::new(&raw[..]);
            let head = read_head(&mut input).unwrap();
            assert!(read_body(&head, &mut input, &mut Vec::new(), u64::MAX).is_err());
        }
    }

    #[test]
    fn the_head_is_read_without_touching_the_body() {
        /// Panics if anything past the head is read.
        struct HeadOnly<'a>(&'a [u8]);
        impl Read for HeadOnly<'_> {
            fn read(&mut self, out: &mut [u8]) -> io::Result<usize> {
                assert!(!self.0.is_empty(), "the body was read");
                let count = out.len().min(self.0.len());
                out[..count].copy_from_slice(&self.0[..count]);
                self.0 = &self.0[count..];
                Ok(count)
            }
        }
        let head = "POST /v1/speech-to-text HTTP/1.1\r\nContent-Length: 3000000000\r\n\
                    Content-Type: application/octet-stream\r\n\r\n";
        let mut input = Input::new(HeadOnly(head.as_bytes()));
        let parsed = read_head(&mut input).unwrap();
        assert_eq!(parsed.content_length(), Some(3_000_000_000));
        assert_eq!(parsed.header("xi-api-key"), None);
        // the server can answer 401 or 413 now, before any body byte
        let mut out = Vec::new();
        write_response(&mut out, 413, &[], br#"{"detail":{}}"#).unwrap();
        let text = String::from_utf8(out).unwrap();
        assert!(text.starts_with("HTTP/1.1 413 Content Too Large\r\n"));
        assert!(text.contains("Connection: close\r\n"));
        assert!(text.contains("Content-Length: 13\r\n"));
    }

    #[test]
    fn query_fields_and_form_fields_merge_with_the_form_last() {
        let body = form(
            "b",
            &[("file", b"AUDIO"), ("timestamps_granularity", b"word")],
        );
        let raw = request(
            &format!(
                "POST /v1/speech-to-text?timestamps_granularity=none&keyterms=Wai+Waï%21 HTTP/1.1\n\
                 Content-Type: multipart/form-data; boundary=\"b\"\nContent-Length: {}\n\n",
                body.len()
            ),
            &body,
        );
        let mut input = Input::new(&raw[..]);
        let head = read_head(&mut input).unwrap();
        assert_eq!(head.path, "/v1/speech-to-text");
        let mut sink = Vec::new();
        let (fields, bytes) = read_body(&head, &mut input, &mut sink, u64::MAX).unwrap();
        assert_eq!((sink.as_slice(), bytes), (&b"AUDIO"[..], 5));
        assert_eq!(
            fields,
            [
                ("timestamps_granularity".into(), "none".into()),
                ("keyterms".into(), "Wai Waï!".into()),
                ("timestamps_granularity".into(), "word".into()),
            ]
        );
    }

    #[test]
    fn a_body_that_is_not_a_form_is_the_audio() {
        let raw = request(
            "POST /v1/speech-to-text?a=1 HTTP/1.1\nContent-Length: 4\n\n",
            b"OggS",
        );
        let mut input = Input::new(&raw[..]);
        let head = read_head(&mut input).unwrap();
        let mut sink = Vec::new();
        let (fields, bytes) = read_body(&head, &mut input, &mut sink, u64::MAX).unwrap();
        assert_eq!((sink.as_slice(), bytes), (&b"OggS"[..], 4));
        assert_eq!(fields, [("a".into(), "1".into())]);
    }

    #[test]
    fn ambiguous_or_oversized_requests_are_refused() {
        let refused = |head: &str| {
            let raw = request(head, b"");
            matches!(
                read_head(&mut Input::new(&raw[..])),
                Err(HttpError::BadRequest(_))
            )
        };
        assert!(refused(
            "POST / HTTP/1.1\nContent-Length: 5\nTransfer-Encoding: chunked\n\n"
        ));
        assert!(refused(
            "POST / HTTP/1.1\nContent-Length: 5\nContent-Length: 5\n\n"
        ));
        assert!(refused(
            "POST / HTTP/1.1\nTransfer-Encoding: gzip, chunked\n\n"
        ));
        assert!(refused(
            "POST / HTTP/1.1\nTransfer-Encoding: chunked\nTransfer-Encoding: chunked\n\n"
        ));
        assert!(refused("POST / HTTP/1.1\nContent-Length: -1\n\n"));
        assert!(refused("POST / HTTP/1.1\nContent-Length: 1e3\n\n"));
        assert!(refused("NOT HTTP\n\n"));
        let huge = format!("POST / HTTP/1.1\nX-Pad: {}\n\n", "a".repeat(MAX_HEAD));
        assert!(refused(&huge));
        assert!(matches!(
            read_head(&mut Input::new(&b""[..])),
            Err(HttpError::Closed)
        ));

        // the cap holds for raw and multipart uploads alike
        let raw = request("POST / HTTP/1.1\nContent-Length: 10\n\n", b"0123456789");
        let mut input = Input::new(&raw[..]);
        let head = read_head(&mut input).unwrap();
        assert!(matches!(
            read_body(&head, &mut input, &mut Vec::new(), 9),
            Err(HttpError::TooLarge)
        ));
        let body = form("b", &[("file", b"0123456789")]);
        assert!(matches!(
            read_multipart(&mut &body[..], "b", &mut Vec::new(), 9),
            Err(HttpError::TooLarge)
        ));
    }

    #[test]
    fn malformed_forms_are_refused() {
        let missing = form("b", &[("model_id", b"x")]);
        assert!(matches!(
            read_multipart(&mut &missing[..], "b", &mut Vec::new(), u64::MAX),
            Err(HttpError::BadRequest("The file field is missing."))
        ));
        let twice = form("b", &[("file", b"a"), ("file", b"b")]);
        assert!(matches!(
            read_multipart(&mut &twice[..], "b", &mut Vec::new(), u64::MAX),
            Err(HttpError::BadRequest(_))
        ));
        let mut cut = form("b", &[("file", b"abc")]);
        cut.truncate(cut.len() - 10);
        assert!(read_multipart(&mut &cut[..], "b", &mut Vec::new(), u64::MAX).is_err());
        let big = vec![b'x'; MAX_FIELDS_BYTES + 1];
        let fat = form("b", &[("keyterms", &big), ("file", b"a")]);
        assert!(matches!(
            read_multipart(&mut &fat[..], "b", &mut Vec::new(), u64::MAX),
            Err(HttpError::BadRequest(_))
        ));
        let many: Vec<(&str, &[u8])> = (0..=MAX_PARTS).map(|_| ("keyterms", &b"t"[..])).collect();
        let crowded = form("b", &many);
        assert!(matches!(
            read_multipart(&mut &crowded[..], "b", &mut Vec::new(), u64::MAX),
            Err(HttpError::BadRequest(_))
        ));
        // a preamble before the first boundary is skipped
        let mut preamble = b"ignored text\r\n".to_vec();
        preamble.extend(form("b", &[("file", b"ok")]));
        let mut sink = Vec::new();
        read_multipart(&mut &preamble[..], "b", &mut sink, u64::MAX).unwrap();
        assert_eq!(sink, b"ok");
    }

    #[test]
    fn content_types_and_query_strings_are_read_strictly() {
        assert_eq!(
            boundary("multipart/form-data; boundary=abc"),
            Some("abc".into())
        );
        assert_eq!(
            boundary("Multipart/Form-Data; charset=utf-8; boundary=\"a b\""),
            Some("a b".into())
        );
        assert_eq!(boundary("audio/ogg"), None);
        assert_eq!(percent_decode("a+b%20c%C3%A9").unwrap(), "a b cé");
        assert!(percent_decode("bad%zz").is_err());
        assert!(percent_decode("cut%4").is_err());
        assert!(percent_decode("%FF").is_err());
        assert_eq!(
            query("a=1&&b&c=%3D").unwrap(),
            [
                ("a".into(), "1".into()),
                ("b".into(), "".into()),
                ("c".into(), "=".into())
            ]
        );
    }
}
