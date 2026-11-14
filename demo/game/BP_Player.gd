# @blueprint v1 - generated from a Blueprint graph. Edit it in the Blueprint editor, not by hand.
class_name BP_Player
extends CharacterBody2D
## Top-down player. Arrow keys move it; coins call Add Score.

signal score_changed(new_score: int)

@export_group("Movement")
## Pixels per second.
@export var speed: float = 220.0
var score: int = 0


func _ready() -> void:
	self.add_to_group(&"player")


func _physics_process(delta: float) -> void:
	velocity = (Input.get_vector(&"ui_left", &"ui_right", &"ui_up", &"ui_down") * speed)
	move_and_slide()


func add_score(amount: int) -> void:
	score = (score + amount)
	score_changed.emit(score)


#region Blueprint graph data (machine-written; edit this file in the Blueprint editor)
#~ {
#~ 	"class_name": "BP_Player",
#~ 	"description": "Top-down player. Arrow keys move it; coins call Add Score.",
#~ 	"dispatchers": [
#~ 		{
#~ 			"name": "score_changed",
#~ 			"params": [
#~ 				[
#~ 					"new_score",
#~ 					"int"
#~ 				]
#~ 			]
#~ 		}
#~ 	],
#~ 	"graphs": [
#~ 		{
#~ 			"id": 1,
#~ 			"inputs": [],
#~ 			"kind": "event",
#~ 			"locals": [],
#~ 			"name": "EventGraph",
#~ 			"next_id": 10,
#~ 			"nodes": [
#~ 				{
#~ 					"d": {},
#~ 					"id": 1,
#~ 					"kind": "event",
#~ 					"p": {
#~ 						"name": "_ready"
#~ 					},
#~ 					"x": 80.0,
#~ 					"y": 80.0
#~ 				},
#~ 				{
#~ 					"d": {
#~ 						"group": "&\"player\""
#~ 					},
#~ 					"id": 3,
#~ 					"kind": "tpl",
#~ 					"p": {
#~ 						"id": "add_to_group"
#~ 					},
#~ 					"x": 320.0,
#~ 					"y": 80.0
#~ 				},
#~ 				{
#~ 					"d": {},
#~ 					"id": 4,
#~ 					"kind": "event",
#~ 					"p": {
#~ 						"name": "_physics_process"
#~ 					},
#~ 					"x": 80.0,
#~ 					"y": 300.0
#~ 				},
#~ 				{
#~ 					"d": {},
#~ 					"id": 5,
#~ 					"kind": "tpl",
#~ 					"p": {
#~ 						"id": "input_vector"
#~ 					},
#~ 					"x": 80.0,
#~ 					"y": 470.0
#~ 				},
#~ 				{
#~ 					"d": {},
#~ 					"id": 6,
#~ 					"kind": "var_get",
#~ 					"p": {
#~ 						"name": "speed"
#~ 					},
#~ 					"x": 330.0,
#~ 					"y": 600.0
#~ 				},
#~ 				{
#~ 					"d": {},
#~ 					"id": 7,
#~ 					"kind": "math",
#~ 					"p": {
#~ 						"n": 2,
#~ 						"op": "*"
#~ 					},
#~ 					"x": 520.0,
#~ 					"y": 500.0
#~ 				},
#~ 				{
#~ 					"d": {},
#~ 					"id": 8,
#~ 					"kind": "set_prop",
#~ 					"p": {
#~ 						"cls": "CharacterBody2D",
#~ 						"prop": "velocity"
#~ 					},
#~ 					"x": 700.0,
#~ 					"y": 300.0
#~ 				},
#~ 				{
#~ 					"d": {},
#~ 					"id": 9,
#~ 					"kind": "call",
#~ 					"p": {
#~ 						"cls": "CharacterBody2D",
#~ 						"method": "move_and_slide"
#~ 					},
#~ 					"x": 980.0,
#~ 					"y": 300.0
#~ 				}
#~ 			],
#~ 			"outputs": [],
#~ 			"pure": false,
#~ 			"sx": 0.0,
#~ 			"sy": 0.0,
#~ 			"wires": [
#~ 				[
#~ 					1,
#~ 					"then",
#~ 					3,
#~ 					"exec"
#~ 				],
#~ 				[
#~ 					5,
#~ 					"ret",
#~ 					7,
#~ 					"a0"
#~ 				],
#~ 				[
#~ 					6,
#~ 					"value",
#~ 					7,
#~ 					"a1"
#~ 				],
#~ 				[
#~ 					7,
#~ 					"ret",
#~ 					8,
#~ 					"value"
#~ 				],
#~ 				[
#~ 					4,
#~ 					"then",
#~ 					8,
#~ 					"exec"
#~ 				],
#~ 				[
#~ 					8,
#~ 					"then",
#~ 					9,
#~ 					"exec"
#~ 				]
#~ 			],
#~ 			"zoom": 1.0
#~ 		},
#~ 		{
#~ 			"id": 2,
#~ 			"inputs": [
#~ 				[
#~ 					"amount",
#~ 					"int"
#~ 				]
#~ 			],
#~ 			"kind": "function",
#~ 			"locals": [],
#~ 			"name": "add_score",
#~ 			"next_id": 7,
#~ 			"nodes": [
#~ 				{
#~ 					"d": {},
#~ 					"id": 1,
#~ 					"kind": "fn_entry",
#~ 					"p": {},
#~ 					"x": 80.0,
#~ 					"y": 120.0
#~ 				},
#~ 				{
#~ 					"d": {},
#~ 					"id": 3,
#~ 					"kind": "var_get",
#~ 					"p": {
#~ 						"name": "score"
#~ 					},
#~ 					"x": 80.0,
#~ 					"y": 300.0
#~ 				},
#~ 				{
#~ 					"d": {},
#~ 					"id": 4,
#~ 					"kind": "math",
#~ 					"p": {
#~ 						"n": 2,
#~ 						"op": "+"
#~ 					},
#~ 					"x": 260.0,
#~ 					"y": 280.0
#~ 				},
#~ 				{
#~ 					"d": {},
#~ 					"id": 5,
#~ 					"kind": "var_set",
#~ 					"p": {
#~ 						"name": "score"
#~ 					},
#~ 					"x": 420.0,
#~ 					"y": 120.0
#~ 				},
#~ 				{
#~ 					"d": {},
#~ 					"id": 6,
#~ 					"kind": "emit",
#~ 					"p": {
#~ 						"name": "score_changed"
#~ 					},
#~ 					"x": 680.0,
#~ 					"y": 120.0
#~ 				}
#~ 			],
#~ 			"outputs": [],
#~ 			"pure": false,
#~ 			"sx": 0.0,
#~ 			"sy": 0.0,
#~ 			"wires": [
#~ 				[
#~ 					1,
#~ 					"then",
#~ 					5,
#~ 					"exec"
#~ 				],
#~ 				[
#~ 					3,
#~ 					"value",
#~ 					4,
#~ 					"a0"
#~ 				],
#~ 				[
#~ 					1,
#~ 					"p_amount",
#~ 					4,
#~ 					"a1"
#~ 				],
#~ 				[
#~ 					4,
#~ 					"ret",
#~ 					5,
#~ 					"value"
#~ 				],
#~ 				[
#~ 					5,
#~ 					"then",
#~ 					6,
#~ 					"exec"
#~ 				],
#~ 				[
#~ 					5,
#~ 					"out",
#~ 					6,
#~ 					"a_new_score"
#~ 				]
#~ 			],
#~ 			"zoom": 1.0
#~ 		}
#~ 	],
#~ 	"parent": "CharacterBody2D",
#~ 	"tool": false,
#~ 	"variables": [
#~ 		{
#~ 			"category": "Movement",
#~ 			"default": "220.0",
#~ 			"export": true,
#~ 			"name": "speed",
#~ 			"tooltip": "Pixels per second.",
#~ 			"type": "float"
#~ 		},
#~ 		{
#~ 			"category": "",
#~ 			"default": "",
#~ 			"export": false,
#~ 			"name": "score",
#~ 			"tooltip": "",
#~ 			"type": "int"
#~ 		}
#~ 	],
#~ 	"version": 1
#~ }
#endregion
