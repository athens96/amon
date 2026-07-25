//go:build !windows

package pet

type WindowSettings struct {
	Enabled              bool
	LocalActivityEnabled bool
	ShowsCurrentTask     bool
	SpritePath           string
	PositionX            *int
	PositionY            *int
}

type Position struct {
	X int
	Y int
}

type Window struct {
	Dashboard      chan struct{}
	TogglePet      chan struct{}
	ToggleActivity chan struct{}
	ToggleTask     chan struct{}
	ImportPet      chan struct{}
	DownloadPets   chan struct{}
	Settings       chan struct{}
	Quit           chan struct{}
	Moved          chan Position
}

func NewWindow(_ WindowSettings) *Window {
	return &Window{
		Dashboard: make(chan struct{}, 1), TogglePet: make(chan struct{}, 1),
		ToggleActivity: make(chan struct{}, 1), ToggleTask: make(chan struct{}, 1),
		ImportPet: make(chan struct{}, 1), DownloadPets: make(chan struct{}, 1),
		Settings: make(chan struct{}, 1), Quit: make(chan struct{}, 1),
		Moved: make(chan Position, 1),
	}
}

func (w *Window) Update(_ []Presentation, _ WindowSettings) {}
func (w *Window) Close()                                    {}
