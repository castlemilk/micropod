use std::fs::{File, OpenOptions};
use std::io;
use std::os::fd::AsRawFd;
use std::os::unix::fs::{MetadataExt, OpenOptionsExt};
use std::path::Path;

pub(super) fn open(path: &Path, read_only: bool) -> io::Result<File> {
    if read_only {
        return File::open(path);
    }

    let file = OpenOptions::new()
        .read(true)
        .write(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK | libc::O_NOCTTY)
        .open(path)?;
    let metadata = file.metadata()?;
    if !metadata.is_file() || metadata.uid() != unsafe { libc::getuid() } || metadata.nlink() != 1 {
        return Err(io::Error::new(
            io::ErrorKind::PermissionDenied,
            "writable disk must be an owned regular file with a single link",
        ));
    }

    if unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) } != 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(file)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::ffi::CString;
    use std::fs;
    use std::io::Write;
    use std::os::unix::ffi::{OsStrExt, OsStringExt};
    use std::os::unix::fs::symlink;
    use std::path::PathBuf;

    struct TempDir(PathBuf);

    impl TempDir {
        fn new() -> Self {
            let template = std::env::temp_dir().join("micropod-vmm-disk-XXXXXX");
            let mut path = CString::new(template.as_os_str().as_bytes())
                .unwrap()
                .into_bytes_with_nul();
            let created = unsafe { libc::mkdtemp(path.as_mut_ptr().cast()) };
            assert!(
                !created.is_null(),
                "mkdtemp: {}",
                io::Error::last_os_error()
            );
            path.pop();
            Self(PathBuf::from(std::ffi::OsString::from_vec(path)))
        }
    }

    impl Drop for TempDir {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }

    #[test]
    fn writer_reopens_fail_until_the_last_duplicate_closes() {
        let temp = TempDir::new();
        let path = temp.0.join("disk.img");
        fs::write(&path, b"disk contents").unwrap();

        let owner = open(&path, false).unwrap();
        let device = owner.try_clone().unwrap();
        let assert_contended = || {
            assert_eq!(
                open(&path, false).unwrap_err().kind(),
                io::ErrorKind::WouldBlock
            );
        };
        assert_contended();
        drop(device);
        assert_contended();

        let device = owner.try_clone().unwrap();
        drop(owner);
        assert_contended();
        drop(device);

        let _next_owner = open(&path, false).unwrap();
        assert_eq!(fs::read(&path).unwrap(), b"disk contents");
    }

    #[test]
    fn writable_disks_reject_links_and_special_files() {
        let temp = TempDir::new();
        let disk = temp.0.join("disk.img");
        fs::write(&disk, b"disk contents").unwrap();

        let symlink_path = temp.0.join("symlink.img");
        symlink(&disk, &symlink_path).unwrap();
        assert_eq!(
            open(&symlink_path, false).unwrap_err().raw_os_error(),
            Some(libc::ELOOP)
        );

        let hardlink = temp.0.join("hardlink.img");
        fs::hard_link(&disk, &hardlink).unwrap();
        for path in [disk.as_path(), hardlink.as_path(), Path::new("/dev/null")] {
            assert_eq!(
                open(path, false).unwrap_err().kind(),
                io::ErrorKind::PermissionDenied
            );
        }
    }

    #[test]
    fn read_only_keeps_existing_access_without_a_writer_lock() {
        let temp = TempDir::new();
        let path = temp.0.join("disk.img");
        fs::write(&path, b"disk contents").unwrap();
        let link = temp.0.join("readonly.img");
        symlink(&path, &link).unwrap();

        let mut reader = open(&link, true).unwrap();
        let _writer = open(&path, false).unwrap();
        let _second_reader = open(&link, true).unwrap();
        assert!(reader.write_all(b"changed").is_err());
        assert!(open(Path::new("/dev/null"), true).is_ok());
    }
}
