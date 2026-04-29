package authcfg

import (
	"encoding/json"
	"fmt"
	"os"
)

// ServerFile is the JSON format for nw-server -auth-file.
// Example: {"users":[{"username":"alice","password":"secret"}]}
type ServerFile struct {
	Users []struct {
		Username string `json:"username"`
		Password string `json:"password"`
	} `json:"users"`
}

// LoadServer returns username -> password map. Empty map means no auth required.
func LoadServer(path string) (map[string]string, error) {
	b, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	var f ServerFile
	if err := json.Unmarshal(b, &f); err != nil {
		return nil, fmt.Errorf("auth file: %w", err)
	}
	out := make(map[string]string, len(f.Users))
	for _, u := range f.Users {
		if u.Username == "" {
			continue
		}
		out[u.Username] = u.Password
	}
	return out, nil
}

// ClientFile is the JSON format for nw-client -auth-file.
// Example: {"username":"alice","password":"secret"}
type ClientFile struct {
	Username string `json:"username"`
	Password string `json:"password"`
}

func LoadClient(path string) (username, password string, err error) {
	b, err := os.ReadFile(path)
	if err != nil {
		return "", "", err
	}
	var f ClientFile
	if err := json.Unmarshal(b, &f); err != nil {
		return "", "", fmt.Errorf("auth file: %w", err)
	}
	if f.Username == "" {
		return "", "", fmt.Errorf("auth file: missing username")
	}
	return f.Username, f.Password, nil
}
