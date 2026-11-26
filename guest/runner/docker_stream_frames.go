package main

import (
	"bufio"
	"encoding/binary"
	"io"
)

func copyFrames(r *bufio.Reader, w io.Writer, stdout, stderr bool) error {
	const headerSize = 8
	selected := func(id byte) bool { return id == 1 && stdout || id == 2 && stderr }
	for {
		header, err := r.Peek(headerSize)
		if err == io.EOF {
			return nil
		}
		if err != nil {
			return err
		}
		payloadSize := int64(binary.BigEndian.Uint32(header[4:]))
		emit := selected(header[0])
		frameSize := headerSize + payloadSize
		if frameSize <= int64(r.Buffered()) {
			// Replay a contiguous run with the same stream selection in one step.
			buffer, _ := r.Peek(r.Buffered())
			end := int(frameSize)
			for len(buffer)-end >= headerSize {
				next := buffer[end:]
				size := headerSize + int64(binary.BigEndian.Uint32(next[4:]))
				if size > int64(len(next)) || selected(next[0]) != emit {
					break
				}
				end += int(size)
			}
			if emit {
				n, err := w.Write(buffer[:end])
				if err != nil {
					return err
				}
				if n != end {
					return io.ErrShortWrite
				}
			}
			r.Discard(end)
			continue
		}

		dst := io.Writer(io.Discard)
		if emit {
			dst = w
		}
		nw, err := dst.Write(header)
		if err != nil {
			return err
		}
		if nw != headerSize {
			return io.ErrShortWrite
		}
		r.Discard(headerSize)
		if _, err = io.CopyN(dst, r, payloadSize); err != nil {
			return err
		}
	}
}
