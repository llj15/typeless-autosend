-- Structure of Typeless 2.8.1's history_v2 table (no data), used to build test databases.
CREATE TABLE `history_v2` (
	`id` text PRIMARY KEY NOT NULL,
	`user_id` text,
	`status` text,
	`mode` text DEFAULT 'voice_transcript',
	`refined_text` text,
	`duration` real,
	`created_at` text,
	`updated_at` text,
	`audio_local_path` text,
	`audio_metadata` text,
	`app_version` text DEFAULT '0.0.0' NOT NULL,
	`mic_device` text,
	`mic_device_info` blob,
	`client_metadata` blob,
	`mode_meta` blob,
	`debug_info` text,
	`audio_context` text
, `server_updated_at` integer, `sync_status` text DEFAULT 'pending_upload' NOT NULL, `sync_attempt_count` integer DEFAULT 0 NOT NULL, `synced_from_cloud` integer DEFAULT false NOT NULL);
CREATE UNIQUE INDEX `history_v2_id_unique` ON `history_v2` (`id`);
CREATE INDEX `idx_history_v2_user_created_at` ON `history_v2` (`user_id`,`created_at`);
CREATE INDEX `idx_history_v2_status` ON `history_v2` (`status`);
CREATE INDEX `idx_history_v2_user_status_created_at` ON `history_v2` (`user_id`,`status`,`created_at`);
CREATE INDEX `idx_history_v2_push_candidate_v2` ON `history_v2` (`user_id`,`sync_status`,`created_at`,`sync_attempt_count`) WHERE "history_v2"."status" = 'completed' AND (("history_v2"."refined_text" IS NOT NULL AND "history_v2"."refined_text" <> '') OR ("history_v2"."mode" = 'voice_command' AND json_extract("history_v2"."mode_meta", '$.ai_result.delivery') = 'external'));
