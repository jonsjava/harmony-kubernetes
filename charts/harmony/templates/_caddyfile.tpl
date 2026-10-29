{{- define "harmony.caddyfile" -}}
{{- $v := .Values.router }}
{{- $fed := printf "%s:3001" (include "harmony.componentName" (dict "root" . "component" "federation-server")) }}
{{- $web := printf "%s:80" (include "harmony.componentName" (dict "root" . "component" "web")) }}
{{- $bot := printf "%s:3002" (include "harmony.componentName" (dict "root" . "component" "bot-gateway")) }}
{{- $media := printf "%s:8080" (include "harmony.componentName" (dict "root" . "component" "media-cache")) }}
{{- $crawlers := "discordbot|slackbot|twitterbot|facebookexternalhit|facebot|telegrambot|whatsapp|linkedinbot|mastodon|pleroma|akkoma|misskey|summalybot|gotosocial|friendica|lemmy|cardyb|synapse|mattermost-bot|zulipurlpreview|discourse|embedly|iframely|redditbot|skypeuripreview|microsoftpreview|vkshare|viber|kakaotalk-scrap" }}
# Harmony router: upstream's self-host/Caddyfile, served over plain HTTP
# behind the cluster's Ingress/Gateway, which terminates TLS.
{
	admin off
	auto_https off
	http_port 8080
	persist_config off
	servers {
		trusted_proxies static {{ $v.trustedProxies }}
		client_ip_headers X-Forwarded-For X-Real-IP
	}
}

(federation_upstream) {
	reverse_proxy {{ $fed }} {
		header_up X-Real-IP {client_ip}
	}
}

:8081 {
	respond /healthz "ok" 200
}

http://{$DOMAIN} {
	encode zstd gzip

	request_body {
		max_size {{ $v.maxBodySize }}
	}

	@notYouTubeRelay not path /youtube-embed.html /embed-player.html
	header @notYouTubeRelay {
		?X-Frame-Options SAMEORIGIN
		?X-Content-Type-Options nosniff
		?X-XSS-Protection "1; mode=block"
		?Referrer-Policy strict-origin-when-cross-origin
	}

	# --- Federation backend ---
	@fedDiscovery path_regexp ^/\.well-known/(webfinger|host-meta|host-meta\.json|nodeinfo)$
	handle @fedDiscovery {
		header Access-Control-Allow-Origin "*" {
			defer
		}
		import federation_upstream
	}

	@fedNodeinfo path_regexp ^/nodeinfo/2\.(0|1)$
	handle @fedNodeinfo {
		header Access-Control-Allow-Origin "*" {
			defer
		}
		import federation_upstream
	}

	@fedExact path_regexp ^/(inbox|oembed)$
	handle @fedExact {
		import federation_upstream
	}
	@fedActorCollections path_regexp ^/users/[^/]+/(inbox|outbox|followers|following|featured)$
	handle @fedActorCollections {
		import federation_upstream
	}
	@fedQuoteAuthorizations path_regexp ^/users/[^/]+/quote_authorizations/[^/]+$
	handle @fedQuoteAuthorizations {
		import federation_upstream
	}
	@fedServers path_regexp ^/servers/
	handle @fedServers {
		import federation_upstream
	}
	@fedPostCollections path_regexp ^/posts/[0-9a-f-]+/(likes|shares|replies|context)
	handle @fedPostCollections {
		import federation_upstream
	}
	@fedMessages path_regexp ^/messages/[0-9a-f-]+$
	handle @fedMessages {
		import federation_upstream
	}
	@fedThreads path_regexp ^/(threads/[0-9a-f-]+(/members)?|channels/[0-9a-f-]+/threads)$
	handle @fedThreads {
		import federation_upstream
	}
	@fedPost path_regexp ^/posts/[0-9a-f-]+$
	handle @fedPost {
		import federation_upstream
	}

	@inviteUnfurl {
		path_regexp ^/invite/[A-Za-z0-9_-]+/?$
		header_regexp User-Agent (?i)({{ $crawlers }})
	}
	handle @inviteUnfurl {
		import federation_upstream
	}

	@driveLinkUnfurl {
		path_regexp ^/d/[A-Za-z0-9_-]{16,64}/?$
		header_regexp User-Agent (?i)({{ $crawlers }})
	}
	handle @driveLinkUnfurl {
		import federation_upstream
	}

	@socialPostAp {
		path_regexp socialPostAp ^/social/post/([0-9a-f-]{36})/?$
		header_regexp Accept (?i)application/(?:activity|ld)\+json
	}
	handle @socialPostAp {
		rewrite * /posts/{re.socialPostAp.1}
		import federation_upstream
	}
	@socialPostUnfurl {
		path_regexp socialPostUnfurl ^/social/post/([0-9a-f-]{36})/?$
		header_regexp User-Agent (?i)(?:{{ $crawlers }})
	}
	handle @socialPostUnfurl {
		rewrite * /posts/{re.socialPostUnfurl.1}
		import federation_upstream
	}

	@socialProfileAp {
		path_regexp socialProfileAp ^/social/profile/([A-Za-z0-9_]+)/?$
		header_regexp Accept (?i)application/(?:activity|ld)\+json
	}
	handle @socialProfileAp {
		rewrite * /users/{re.socialProfileAp.1}
		import federation_upstream
	}

	@publicPageApp {
		path_regexp ^/@[^/]+(/[^/]+)?/?$
		expression {http.request.cookie.harmony_app} == "1"
		not header_regexp Accept (?i)application/(?:activity|ld)\+json
	}
	handle @publicPageApp {
		header {
			+Vary "Accept, Cookie"
			Cache-Control "private, no-cache"
			defer
		}
		reverse_proxy {{ $web }}
	}
	@publicPage path_regexp ^/@[^/]+(/[^/]+)?/?$
	handle @publicPage {
		import federation_upstream
	}

	@fedActivities path_regexp ^/(users/[^/]+/)?activities/[0-9a-f-]+$
	handle @fedActivities {
		import federation_upstream
	}

	@fedActor {
		path_regexp ^/users/[^/]+$
		header_regexp Accept (?i)application/(activity\+json|ld\+json|json)
	}
	handle @fedActor {
		import federation_upstream
	}
	@humanActor {
		path_regexp humanActor ^/users/([^/]+)$
		not header_regexp Accept (?i)application/(activity\+json|ld\+json|json)
	}
	handle @humanActor {
		redir * /@{re.humanActor.1} 302
	}

	@fedPrefix path_regexp ^/(health|link-preview)
	handle @fedPrefix {
		import federation_upstream
	}

	@fedLivekit path_regexp ^/api/livekit/
	handle @fedLivekit {
		import federation_upstream
	}

	@fedApi path_regexp ^/api/federation/
	handle @fedApi {
		uri strip_prefix /api/federation
		import federation_upstream
	}

	@fedChannelWebhooks path_regexp ^/webhooks/channels/
	handle @fedChannelWebhooks {
		request_body {
			max_size 1MB
		}
		import federation_upstream
	}

	@fedWebhooks path_regexp ^/webhooks/
	handle @fedWebhooks {
		request_body {
			max_size 64KB
		}
		import federation_upstream
	}

	{{- if .Values.botGateway.enabled }}

	# --- Bot gateway ---
	@botGateway path_regexp ^/bot-gateway/
	handle @botGateway {
		uri strip_prefix /bot-gateway
		reverse_proxy {{ $bot }} {
			header_up X-Real-IP {client_ip}
		}
	}
	{{- end }}

	@slashless path_regexp ^/(api/livekit|api/federation|webhooks|bot-gateway)$
	handle @slashless {
		redir * {path}/{?query} 301
	}

	# --- Frontend ---
	handle {
		reverse_proxy {{ $web }}
	}
}
{{- if .Values.supabase.proxy.enabled }}

http://{$DB_DOMAIN} {
	@logoutScope {
		path /auth/v1/logout /auth/v1/logout/
		not method OPTIONS
		not expression {http.request.uri.query} == "scope=local"
	}
	handle @logoutScope {
		header Content-Type application/json
		header Access-Control-Allow-Origin *
		header Cache-Control no-store
		respond `{"code":403,"error_code":"logout_scope_forbidden","msg":"Only this device can be signed out here. Sign out other devices from Settings, Sessions."}` 403
	}

	@publicRender path /storage/v1/render/image/public/*
	request_header @publicRender Accept "image/webp,*/*;q=0.8"

	{{- if .Values.mediaCache.enabled }}

	@publicMedia {
		method GET HEAD
		path /storage/v1/object/public/* /storage/v1/render/image/public/*
		not path /storage/v1/object/public/message_media/* /storage/v1/render/image/public/message_media/*
	}
	handle @publicMedia {
		reverse_proxy {{ $media }}
	}
	{{- end }}

	handle {
		{{- if eq (include "harmony.kongScheme" .) "https" }}
		reverse_proxy https://{{ include "harmony.kongHostPort" . }} {
			header_up Host {upstream_hostport}
		}
		{{- else }}
		reverse_proxy {{ include "harmony.kongHostPort" . }}
		{{- end }}
	}
}
{{- end }}
{{- end }}
