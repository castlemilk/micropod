package lib

import "github.com/google/uuid"

// ID makes the newmod variant need one module the base variant does not.
func ID() string { return uuid.NewString() }
