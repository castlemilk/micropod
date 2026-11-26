fn main() {
    let mut b = itoa::Buffer::new();
    cfg_if::cfg_if! { if #[cfg(unix)] { println!("{}", b.format(42)); } else { println!("other"); } }
}
