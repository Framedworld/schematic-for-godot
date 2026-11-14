# @blueprint v1 - generated from a Blueprint graph. Edit it in the Blueprint editor, not by hand.
class_name BP_HUD
extends Label
## Shows the player's score by listening to its score_changed dispatcher.


func _ready() -> void:
	var as_bp_player_4: BP_Player = get_tree().get_first_node_in_group(&"player") as BP_Player
	if as_bp_player_4 != null:
		if not as_bp_player_4.score_changed.is_connected(OnScoreChanged):
			as_bp_player_4.score_changed.connect(OnScoreChanged)


func OnScoreChanged(new_score: int) -> void:
	text = "Score: {score}".format({"score": new_score})


#region Blueprint graph data (machine-written; edit this file in the Blueprint editor)
#~ {
#~ 	"class_name": "BP_HUD",
#~ 	"description": "Shows the player's score by listening to its score_changed dispatcher.",
#~ 	"dispatchers": [],
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
#~ 						"id": "get_first_node_in_group"
#~ 					},
#~ 					"x": 80.0,
#~ 					"y": 260.0
#~ 				},
#~ 				{
#~ 					"d": {},
#~ 					"id": 4,
#~ 					"kind": "cast",
#~ 					"p": {
#~ 						"cls": "BP_Player"
#~ 					},
#~ 					"x": 340.0,
#~ 					"y": 80.0
#~ 				},
#~ 				{
#~ 					"d": {},
#~ 					"id": 5,
#~ 					"kind": "bind_signal",
#~ 					"p": {
#~ 						"cls": "BP_Player",
#~ 						"signal": "score_changed"
#~ 					},
#~ 					"x": 660.0,
#~ 					"y": 80.0
#~ 				},
#~ 				{
#~ 					"d": {},
#~ 					"id": 6,
#~ 					"kind": "event_ref",
#~ 					"p": {
#~ 						"fn": "OnScoreChanged"
#~ 					},
#~ 					"x": 420.0,
#~ 					"y": 280.0
#~ 				},
#~ 				{
#~ 					"d": {},
#~ 					"id": 7,
#~ 					"kind": "custom_event",
#~ 					"p": {
#~ 						"name": "OnScoreChanged",
#~ 						"params": [
#~ 							[
#~ 								"new_score",
#~ 								"int"
#~ 							]
#~ 						]
#~ 					},
#~ 					"x": 80.0,
#~ 					"y": 460.0
#~ 				},
#~ 				{
#~ 					"d": {},
#~ 					"id": 8,
#~ 					"kind": "format",
#~ 					"p": {
#~ 						"text": "Score: {score}"
#~ 					},
#~ 					"x": 300.0,
#~ 					"y": 600.0
#~ 				},
#~ 				{
#~ 					"d": {},
#~ 					"id": 9,
#~ 					"kind": "set_prop",
#~ 					"p": {
#~ 						"cls": "Label",
#~ 						"prop": "text"
#~ 					},
#~ 					"x": 620.0,
#~ 					"y": 460.0
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
#~ 					4,
#~ 					"exec"
#~ 				],
#~ 				[
#~ 					3,
#~ 					"ret",
#~ 					4,
#~ 					"obj"
#~ 				],
#~ 				[
#~ 					4,
#~ 					"then",
#~ 					5,
#~ 					"exec"
#~ 				],
#~ 				[
#~ 					4,
#~ 					"as",
#~ 					5,
#~ 					"target"
#~ 				],
#~ 				[
#~ 					6,
#~ 					"fn",
#~ 					5,
#~ 					"fn"
#~ 				],
#~ 				[
#~ 					7,
#~ 					"then",
#~ 					9,
#~ 					"exec"
#~ 				],
#~ 				[
#~ 					7,
#~ 					"p_new_score",
#~ 					8,
#~ 					"f_score"
#~ 				],
#~ 				[
#~ 					8,
#~ 					"ret",
#~ 					9,
#~ 					"value"
#~ 				]
#~ 			],
#~ 			"zoom": 1.0
#~ 		}
#~ 	],
#~ 	"parent": "Label",
#~ 	"tool": false,
#~ 	"variables": [],
#~ 	"version": 1
#~ }
#endregion
