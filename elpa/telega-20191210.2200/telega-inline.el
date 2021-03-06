;;; telega-inline.el --- Support for inline stuff  -*- lexical-binding:t -*-

;; Copyright (C) 2019 by Zajcev Evgeny.

;; Author: Zajcev Evgeny <zevlg@yandex.ru>
;; Created: Thu Feb 14 04:51:54 2019
;; Keywords:

;; telega is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; telega is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with telega.  If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:

;; Inline bots support

;;  @gif @youtube @pic @vid etc

;;; Code:
(require 'telega-core)

(declare-function telega-browse-url "telega-webpage" (url &optional in-web-browser))
(declare-function telega-chatbuf-input-insert "telega-chat" (imc))
(declare-function telega-chatbuf-attach-inline-bot-query "telega-chat" (&optional no-empty-search))
(declare-function telega-chat--pop-to-buffer "telega-chat" (chat))

(defvar telega--inline-bot nil
  "BOT value for the inline results help buffer.")
(defvar telega--inline-query nil
  "Query string in help buffer.")
(defvar telega--inline-results nil
  "Value for `inlineQueryResults' in help buffer.")


(defun telega--on-callbackQueryAnswer (reply)
  "Handle callback reply answer."
  (let ((text (telega-tl-str reply :text))
        (link (plist-get reply :url)))
    (if (plist-get reply :show_alert)
        ;; Popup message from the bot
        (with-telega-help-win "*Callback Alert*"
          (telega-ins text)
          (unless (string-empty-p link)
            (telega-ins "\n")
            (telega-ins--raw-button (telega-link-props 'url link)
              (telega-ins link))))

      (message text)
      (unless (string-empty-p link)
        (telega-browse-url link)))))

(defun telega--getCallbackQueryAnswer (msg payload)
  "Async send callback to bot."
  (telega-server--send
   (list :@type "getCallbackQueryAnswer"
         :chat_id (plist-get msg :chat_id)
         :message_id (plist-get msg :id)
         :payload payload)))

(defun telega-inline--callback (kbd-button msg)
  "Generate callback function for KBD-BUTTON."
  (let ((kbd-type (plist-get kbd-button :type)))
    (cl-ecase (telega--tl-type kbd-type)
      (inlineKeyboardButtonTypeUrl
       (telega-browse-url (plist-get kbd-type :url)))

      (inlineKeyboardButtonTypeCallback
       (telega--getCallbackQueryAnswer
        msg (list :@type "callbackQueryPayloadData"
                  :data (plist-get kbd-type :data))))

      (inlineKeyboardButtonTypeSwitchInline
       ;; Generate another inline query to the bot
       (let* ((via-bot-user-id (plist-get msg :via_bot_user_id))
              (sender-user-id (plist-get msg :sender_user_id))
              (bot-user-id (if (zerop via-bot-user-id)
                               sender-user-id
                             via-bot-user-id))
              (bot (unless (zerop bot-user-id)
                     (telega-user--get bot-user-id)))
              (new-query (telega-tl-str kbd-type :query)))
         (when (and bot (telega-user-bot-p bot))
           (unless (plist-get kbd-type :in_current_chat)
             (telega-chat--pop-to-buffer
              (telega-completing-read-chat "To chat: ")))

           (telega-chatbuf--input-delete)
           (telega-chatbuf-input-insert
            (concat "@" (telega-tl-str bot :username) " " new-query))
           (telega-chatbuf-attach-inline-bot-query 'no-search))))

      (inlineKeyboardButtonTypeCallbackGame
       (telega--getCallbackQueryAnswer
        msg (list :@type "callbackQueryPayloadGame"
                  :game_short_name
                  (telega--tl-get msg :content :game :short_name))))
      ;; TODO: other types
      )))

(defun telega-inline--help-echo (kbd-button _msg)
  "Generate help-echo value for KBD-BUTTON."
  (let ((kbd-type (plist-get kbd-button :type)))
    (cl-case (telega--tl-type kbd-type)
      (inlineKeyboardButtonTypeUrl (plist-get kbd-type :url))
      )))


(defun telega--getInlineQueryResults (bot-user query &optional chat
                                               offset location callback)
  "Query BOT-ID for the QUERY."
  (declare (indent 5))
  (telega-server--call
   (nconc (list :@type "getInlineQueryResults"
                :bot_user_id (plist-get bot-user :id)
                :query query)
          (when chat
            (list :chat_id (plist-get chat :id)))
          (when location
            (list :location location))
          (when offset
            (list :offset offset)))
   callback))

(defun telega-ins--inline-delim ()
  "Inserter for the delimiter."
  (telega-ins--with-props
      '(face default display ((space-width 2) (height 0.5)))
    (telega-ins (make-string 30 ?─) "\n")))

(defun telega-inline-bot--action (qr)
  "Action to take when corresponding query result QR button is pressed."
  (cl-assert telega--chat)
  (cl-assert telega--inline-bot)
  (cl-assert telega--inline-results)
  (cl-assert (eq major-mode 'help-mode))

  (let ((chat telega--chat)
        (inline-query telega--inline-query)
        (inline-results telega--inline-results)
        (bot telega--inline-bot))
    ;; NOTE: Kill help win before modifying chatbuffer, because it
    ;; recovers window configuration on kill
    (quit-window 'kill-buffer)

    (let* ((thumb (cl-case (telega--tl-type qr)
                    (inlineQueryResultAnimation
                     (telega--tl-get qr :animation :thumbnail))
                    (inlineQueryResultArticle
                     (plist-get qr :thumbnail))
                    (inlineQueryResultPhoto
                     (telega-photo--thumb (plist-get qr :photo)))
                    (inlineQueryResultGame
                     (telega-photo--thumb (telega--tl-get qr :game :photo)))
                    (inlineQueryResultVideo
                     (telega--tl-get qr :video :thumbnail))))
           (thumb-file (when thumb (telega-file--renew thumb :photo)))
           (thumb-img (when (telega-file--downloaded-p thumb-file)
                        (create-image (telega--tl-get thumb-file :local :path)
                                      (when (fboundp 'imagemagick-types) 'imagemagick) nil
                                      :scale 1.0 :ascent 'center
                                      :height (telega-chars-xheight 1)))))
      (with-telega-chatbuf chat
        (telega-chatbuf--input-delete)
        (telega-chatbuf-input-insert
         (list :@type "telegaInlineQuery"
               :preview thumb-img
               :caption (substring (plist-get qr :@type) 17)
               :query inline-query
               :via-bot bot
               :hide-via-bot current-prefix-arg
               :query-id (plist-get inline-results :inline_query_id)
               :result-id (plist-get qr :id)))))))

(defun telega-ins--inline-audio (qr)
  "Inserter for `inlineQueryResultAudio' QR."
  (let ((audio (plist-get qr :audio)))
    (telega-ins--audio nil audio telega-symbol-audio)
    (telega-ins "\n")))

(defun telega-ins--inline-voice-note (qr)
  "Inserter for `inlineQueryResultVoiceNote' QR."
  (let ((voice-note (plist-get qr :voice_note)))
    (telega-ins (plist-get qr :title) "\n")
    (telega-ins--voice-note nil voice-note)
    (telega-ins "\n")))

(defun telega-ins--inline-sticker (qr)
  "Inserter for `inlineQueryResultSticker' QR."
  (let ((sticker (plist-get qr :sticker)))
    (telega-ins--sticker-image sticker)))

(defun telega-ins--inline-animation (qr)
  "Inserter for `inlineQueryResultAnimation' QR."
  (let ((anim (plist-get qr :animation)))
    (telega-ins--animation-image anim)))

(defun telega-ins--inline-photo (qr)
  "Inserter for `inlineQueryResultPhoto' QR."
  (let ((photo (plist-get qr :photo)))
    (telega-ins--image
     (telega-photo--image photo (cons 10 3)))))

(defun telega-ins--inline-document (qr)
  "Inserter for `inlineQueryResultDocument' QR."
  (let* ((doc (plist-get qr :document))
         (thumb (plist-get doc :thumbnail))
         (thumb-img (when thumb
                      (telega-media--image
                       (cons thumb 'telega-thumb--create-image-two-lines)
                       (cons thumb :photo)))))
    (telega-ins--document-header doc)
    (telega-ins "\n")

    ;; documents thumbnail preview (if any)
    (when thumb-img
      (telega-ins--image thumb-img 0))
    (telega-ins " " (telega-tl-str qr :title) "\n")
    (when thumb-img
      (telega-ins--image thumb-img 1))
    (telega-ins " " (telega-tl-str qr :description) "\n")))

(defun telega-ins--inline-article (qr)
  "Inserter for `inlineQueryResultArticle' QR."
  (let* ((thumb (plist-get qr :thumbnail))
         (thumb-img (when thumb
                      (telega-media--image
                       (cons thumb 'telega-thumb--create-image-two-lines)
                       (cons thumb :photo)))))
    (when thumb-img
      (telega-ins--image thumb-img 0))
    (telega-ins " " (telega-tl-str qr :title) "\n")
    (when thumb-img
      (telega-ins--image thumb-img 1))
    (telega-ins " " (telega-tl-str qr :description) "\n")
    ))

(defun telega-ins--inline-video (qr)
  "Inserter for `inlineQueryResultVideo' QR."
  (let* ((video (plist-get qr :video))
         (thumb (plist-get video :thumbnail))
         (thumb-img (when thumb
                      (telega-media--image
                       (cons thumb 'telega-thumb--create-image-two-lines)
                       (cons thumb :photo)))))
    (when thumb-img
      (telega-ins--image thumb-img 0)
      (telega-ins " "))
    (telega-ins (telega-tl-str qr :title))
    (telega-ins "\n")
    (when thumb-img
      (telega-ins--image thumb-img 1)
      (telega-ins " "))
    (telega-ins-fmt "%dx%d %s"
      (plist-get video :width)
      (plist-get video :height)
      (telega-duration-human-readable (plist-get video :duration)))
    (telega-ins "\n")))

(defun telega-ins--inline-game (qr)
  "Inserter for `inlineQueryResultGame' QR."
  (let* ((game (plist-get qr :game))
         (photo (plist-get game :photo))
         (photo-img (when photo
                      (telega-photo--image photo (cons 4 2)))))
    (when photo-img
      (telega-ins--image photo-img 0)
      (telega-ins " "))
    (telega-ins--with-face 'bold
      (telega-ins (telega-tl-str game :title)))
    (telega-ins "\n")
    (when photo-img
      (telega-ins--image photo-img 1)
      (telega-ins " "))
    (telega-ins (telega-tl-str game :description))
    (telega-ins "\n")))

(defun telega-inline-bot--gen-callback (bot query &optional for-chat)
  "Generate callback for the BOT's QUERY result handling in FOR-CHAT."
  (lambda (reply)
    (if-let ((qr-results (append (plist-get reply :results) nil)))
        (with-telega-help-win "*Telegram Inline Results*"
          (visual-line-mode 1)
          (setq telega--inline-bot bot)
          (setq telega--inline-query query)
          (setq telega--inline-results reply)
          (setq telega--chat for-chat)

          (dolist (qr qr-results)
            ;; NOTE: possible insert the delimiter, so mixing for
            ;; example Articles and Animations is possible
            (when (memq (telega--tl-type qr)
                        '(inlineQueryResultVideo
                          inlineQueryResultAudio
                          inlineQueryResultArticle
                          inlineQueryResultDocument
                          inlineQueryResultGame))
              (unless (or (= (point) (point-at-bol))
                          (= (point) 1))
                (telega-ins "\n")
                (telega-ins--inline-delim)))

            (cl-case (telega--tl-type qr)
              (inlineQueryResultDocument
               (telega-button--insert 'telega qr
                 :inserter 'telega-ins--inline-document
                 :action 'telega-inline-bot--action
                 'cursor-sensor-functions
                 '(telega-button-highlight--sensor-func))
               (telega-ins--inline-delim))

              (inlineQueryResultVideo
               (telega-button--insert 'telega qr
                 :inserter 'telega-ins--inline-video
                 :action 'telega-inline-bot--action
                 'cursor-sensor-functions
                 '(telega-button-highlight--sensor-func))
               (telega-ins--inline-delim))

              (inlineQueryResultAudio
               (telega-button--insert 'telega qr
                 :inserter 'telega-ins--inline-audio
                 :action 'telega-inline-bot--action
                 'cursor-sensor-functions
                 '(telega-button-highlight--sensor-func))
               (telega-ins--inline-delim))

              (inlineQueryResultVoiceNote
               (telega-button--insert 'telega qr
                 :inserter 'telega-ins--inline-voice-note
                 :action 'telega-inline-bot--action
                 'cursor-sensor-functions
                 '(telega-button-highlight--sensor-func))
               (telega-ins--inline-delim))

              (inlineQueryResultArticle
               (telega-button--insert 'telega qr
                 :inserter 'telega-ins--inline-article
                 :action 'telega-inline-bot--action
                 'cursor-sensor-functions
                 '(telega-button-highlight--sensor-func))
               (telega-ins--inline-delim))

              (inlineQueryResultAnimation
               (telega-button--insert 'telega qr
                 :inserter 'telega-ins--inline-animation
                 :action 'telega-inline-bot--action
                 'cursor-sensor-functions
                 (list (telega-animation--gen-sensor-func
                        (plist-get qr :animation)))
                 'help-echo (when-let ((title (telega-tl-str qr :title)))
                              (unless (string-empty-p title)
                                (format "GIF title: %s" title)))))

              (inlineQueryResultPhoto
               (telega-button--insert 'telega qr
                 :inserter 'telega-ins--inline-photo
                 :action 'telega-inline-bot--action))

              (inlineQueryResultSticker
               (telega-button--insert 'telega qr
                 :inserter 'telega-ins--inline-sticker
                 :action 'telega-inline-bot--action))

              (inlineQueryResultGame
               (telega-button--insert 'telega qr
                 :inserter 'telega-ins--inline-game
                 :action 'telega-inline-bot--action)
               (telega-ins--inline-delim))

              (t
               (telega-ins-fmt "* %S\n" qr)))))

      ;; Not found
      (unless (string-empty-p query)
        (message "telega: @%s Nothing found for %s"
                 (plist-get bot :username) (propertize query 'face 'bold)))
      )))

(defun telega-inline-bot-query (bot query for-chat)
  "Query BOT for inline results for the QUERY."
  (with-telega-chatbuf for-chat
    ;; Cancel currently active inline-query loading
    (when (telega-server--callback-get telega-chatbuf--inline-query)
      (telega-server--callback-put telega-chatbuf--inline-query 'ignore))

    (message "telega: @%s Searching for %s..."
             (telega-tl-str bot :username) (propertize query 'face 'bold))
    (setq telega-chatbuf--inline-query
          (telega--getInlineQueryResults bot query for-chat nil nil
            (telega-inline-bot--gen-callback bot query for-chat)))))

(provide 'telega-inline)

;;; telega-inline.el ends here
