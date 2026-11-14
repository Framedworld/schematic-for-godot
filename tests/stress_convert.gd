extends SceneTree
## Stress test of the GDScript -> Schematic converter over any folders of scripts. It reads only.
##
##   godot --headless --path . --script res://tests/stress_convert.gd -- <folder> [<folder>...] [--limit=N] [--tag=name]
##
## Every distinct script is converted and the result is checked as far as this project allows:
##   - the converter and the compiler must not raise a script error or report one of their own;
##   - nothing written in the source may go missing: every string, number, node path and name is still there;
##   - where the original loads here, the converted script must load too, and must have the same functions,
##     properties (with the same default values), signals and constants;
##   - where the original does not load here (it needs its own project's classes), GDScript must complain about
##     the converted script in the same words as about the original;
##   - saving the schematic and reading it back must give the same script.
## The findings go to tests/out/stress/<tag>.txt, most common first. A script that extends a class or a file
## of its own project cannot be judged here; put the script in a project that has them and run this there.
##
## Scripts that lean on their project's own classes and autoloads are judged inside that project: copy the
## project's scripts to a scratch folder with this plugin and these tests, let Godot import it, and run
##   godot --headless --path <copy> res://tests/stress_convert.tscn -- res://
## (a scene, so that the project's autoloads exist).

func _init() -> void:
	load("res://tests/stress_runner.gd").new().run()
	quit()
