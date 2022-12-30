port module Main exposing (Event, Model, Msg(..), PersistedModel, User, defaultModel, main, modelDecoder, modelEncoder)

import Browser
import Browser.Dom as Dom
import Duration
import Html exposing (Attribute, Html, a, br, button, div, footer, form, header, img, input, label, li, ol, option, select, span, text)
import Html.Attributes as Attr
import Html.Events exposing (onCheck, onClick, onInput, onSubmit)
import Json.Decode
import Json.Encode
import MobSession
import Random
import Random.List
import Task
import Time


main : Program Json.Encode.Value Model Msg
main =
    Browser.element
        { init = init
        , view = view
        , update = updateWithStorage
        , subscriptions = subscriptions
        }


type alias InitializerFlags =
    { persisted : Maybe PersistedModel, gitRef : String }


appDecoder : Json.Decode.Decoder InitializerFlags
appDecoder =
    Json.Decode.map2 InitializerFlags
        (Json.Decode.maybe (Json.Decode.field "persisted" modelDecoder))
        (Json.Decode.field "gitRef" Json.Decode.string)


init : Json.Encode.Value -> ( Model, Cmd Msg )
init flags =
    ( case Json.Decode.decodeValue appDecoder flags of
        Ok decoded ->
            let
                persisted =
                    Maybe.withDefault defaultPersistedModel decoded.persisted
            in
            { defaultModel
                | users =
                    persisted.users
                        |> List.map (\persistedUser -> { username = persistedUser.username, avatarUrl = getGithubAvatarUrl persistedUser.username })
                , enabledSound = persisted.enabledSound
                , enabledNotification = persisted.enabledNotification
                , intervalSeconds = persisted.intervalSeconds
                , gitRef = decoded.gitRef
            }

        Err _ ->
            defaultModel
    , Cmd.none
    )


type Event
    = Start
    | Stop
    | Stay


type Msg
    = InputUsername String
    | AddUser
    | ShuffleUsers
    | UpdateUsers (List User)
    | Tick Time.Posix
    | UpdateInterval MobSession.IntervalUnit String
    | UpdateMobbing Bool
    | ResetTimer
    | FallbackAvatar String
    | UpdateSoundMode Bool
    | UpdateNotificationMode Bool
    | UpdateDurations Event Time.Posix
    | CheckMobSession
    | NoOp


type alias User =
    { username : String
    , avatarUrl : String
    }


type alias PersistedUser =
    -- Keep record style for easier extending even if actually one field exists
    { username : String }


type alias Model =
    { inputtedUsername : String
    , users : List User
    , intervalSeconds : Int
    , mobbing : Bool
    , enabledSound : Bool
    , enabledNotification : Bool
    , gitRef : String
    , durations : List Duration.Duration
    , moment : Time.Posix
    }


type alias PersistedModel =
    -- TODO: Consider to versioning config structure with `andThen`
    -- enabledNotification does not mean to be notified, because users can change the permission without app layer. This mean to try.
    { users : List PersistedUser, enabledSound : Bool, enabledNotification : Bool, intervalSeconds : Int }


defaultModel : Model
defaultModel =
    { users = []
    , inputtedUsername = ""
    , intervalSeconds = 30 * 60
    , mobbing = False
    , enabledSound = True
    , enabledNotification = False
    , gitRef = "unknown ref"
    , durations = []
    , moment = Time.millisToPosix 0
    }


defaultPersistedModel : PersistedModel
defaultPersistedModel =
    { users = defaultModel.users |> List.map (\user -> { username = user.username })
    , enabledSound = defaultModel.enabledSound
    , enabledNotification = defaultModel.enabledNotification
    , intervalSeconds = defaultModel.intervalSeconds
    }


userEncoder : User -> Json.Encode.Value
userEncoder user =
    Json.Encode.object [ ( "username", Json.Encode.string user.username ) ]


modelEncoder : Model -> Json.Encode.Value
modelEncoder model =
    Json.Encode.object
        [ ( "users", Json.Encode.list userEncoder model.users )
        , ( "enabledSound", Json.Encode.bool model.enabledSound )
        , ( "enabledNotification", Json.Encode.bool model.enabledNotification )
        , ( "intervalSeconds", Json.Encode.int model.intervalSeconds )
        ]


userDecoder : Json.Decode.Decoder PersistedUser
userDecoder =
    Json.Decode.map PersistedUser
        (Json.Decode.field "username" Json.Decode.string)


modelDecoder : Json.Decode.Decoder PersistedModel
modelDecoder =
    Json.Decode.map4 PersistedModel
        (Json.Decode.field "users" (Json.Decode.list userDecoder))
        (Json.Decode.field "enabledSound" Json.Decode.bool)
        (Json.Decode.field "enabledNotification" Json.Decode.bool)
        (Json.Decode.field "intervalSeconds" Json.Decode.int)


fallbackAvatarUrl : String
fallbackAvatarUrl =
    "/images/default-profile-icon.png"


update : Msg -> Model -> ( Model, Cmd Msg )
update msg model =
    case msg of
        InputUsername input ->
            ( { model | inputtedUsername = input }, Cmd.none )

        AddUser ->
            ( if isAddableUser model then
                let
                    username =
                        String.trim model.inputtedUsername
                in
                { model
                    | inputtedUsername = ""
                    , users = model.users ++ [ { username = username, avatarUrl = getGithubAvatarUrl username } ]
                }

              else
                model
            , Task.attempt (\_ -> NoOp) (Dom.focus "username-input")
            )

        UpdateInterval unit input ->
            ( { model
                | intervalSeconds =
                    case String.toInt input of
                        Just int ->
                            MobSession.updateIntervalSeconds int unit model.intervalSeconds

                        _ ->
                            model.intervalSeconds
              }
            , Cmd.none
            )

        UpdateSoundMode enabled ->
            ( { model | enabledSound = enabled }, Cmd.none )

        UpdateNotificationMode enabled ->
            ( { model | enabledNotification = enabled }, Cmd.none )

        ShuffleUsers ->
            ( model, Random.generate UpdateUsers <| Random.List.shuffle model.users )

        UpdateUsers newUsers ->
            ( { model | users = newUsers }, Cmd.none )

        UpdateMobbing mobbing ->
            ( { model | mobbing = mobbing }
            , Task.perform
                (UpdateDurations
                    (case ( model.mobbing == mobbing, mobbing ) of
                        ( True, _ ) ->
                            Stay

                        ( False, True ) ->
                            Start

                        ( False, False ) ->
                            Stop
                    )
                )
                Time.now
            )

        UpdateDurations event moment ->
            ( { model
                | moment = moment
                , durations =
                    case event of
                        Start ->
                            ( moment, moment ) :: model.durations

                        _ ->
                            Duration.updateLatest moment model.durations
              }
            , if event == Stay then
                -- https://medium.com/elm-shorts/how-to-turn-a-msg-into-a-cmd-msg-in-elm-5dd095175d84
                Task.succeed CheckMobSession |> Task.perform identity

              else
                Cmd.none
            )

        ResetTimer ->
            ( { model | mobbing = False, durations = [] }, Cmd.none )

        CheckMobSession ->
            if Duration.elapsedSecondsFromDurations model.durations >= model.intervalSeconds then
                ( { model
                    | mobbing = False
                    , users = MobSession.rotate model.users
                    , durations = []
                  }
                , Cmd.batch
                    [ if model.enabledSound then
                        playSound "/audio/meow.mp3"

                      else
                        Cmd.none
                    , if model.enabledNotification then
                        notify "🚗 Change the driver! 🚗"

                      else
                        Cmd.none
                    ]
                )

            else
                ( model, Cmd.none )

        Tick _ ->
            ( model
            , Task.perform
                (UpdateDurations Stay)
                Time.now
            )

        FallbackAvatar username ->
            let
                setFallbackAvatar user =
                    { user
                        | avatarUrl =
                            if user.username == username then
                                fallbackAvatarUrl

                            else
                                user.avatarUrl
                    }
            in
            ( { model | users = model.users |> List.map setFallbackAvatar }
            , Cmd.none
            )

        NoOp ->
            ( model, Cmd.none )


port setStorage : Json.Encode.Value -> Cmd msg


port playSound : String -> Cmd msg


port notify : String -> Cmd msg


updateWithStorage : Msg -> Model -> ( Model, Cmd Msg )
updateWithStorage msg oldModel =
    let
        ( newModel, cmds ) =
            update msg oldModel
    in
    ( newModel
    , Cmd.batch [ setStorage (modelEncoder newModel), cmds ]
    )


isAddableUser : Model -> Bool
isAddableUser model =
    let
        normalizedUsername : String
        normalizedUsername =
            String.trim model.inputtedUsername
    in
    not
        (String.isEmpty normalizedUsername
            || List.member normalizedUsername (List.map (\user -> user.username) model.users)
        )


balloon : ( String, String ) -> List (Attribute msg)
balloon ( label, pos ) =
    [ Attr.attribute "data-balloon-visible" "true"
    , Attr.attribute "aria-label" label
    , Attr.attribute "data-balloon-pos" pos
    ]


addUserInput : Model -> Html Msg
addUserInput model =
    div [ Attr.class "list-item" ]
        [ li []
            [ form [ onSubmit AddUser ]
                [ input [ Attr.id "username-input", Attr.value model.inputtedUsername, onInput InputUsername, Attr.placeholder "Username", Attr.type_ "text" ] []
                , button
                    ((if satisfiedMinMembers model then
                        []

                      else
                        balloon ( "mob needs 2+ members!", "down" )
                     )
                        ++ [ Attr.class "button", Attr.disabled (not (model |> isAddableUser)) ]
                    )
                    [ emoji "➕" ]
                ]
            ]
        ]


deleteUser : User -> List User -> List User
deleteUser leaver users =
    users |> List.filter (\user -> not (user.username == leaver.username))


userPanel : Model -> Html Msg
userPanel model =
    div [ Attr.class "users-panel" ]
        [ ol []
            ((model.users
                |> List.map
                    (\user ->
                        li []
                            [ div [ Attr.class "list-item" ]
                                [ img
                                    ([ Attr.class "user-image"
                                     , Attr.src user.avatarUrl
                                     ]
                                        ++ (if user.avatarUrl == fallbackAvatarUrl then
                                                []

                                            else
                                                [ onError (FallbackAvatar user.username) ]
                                           )
                                    )
                                    []
                                , text user.username
                                , button [ onClick (UpdateUsers (model.users |> deleteUser user)), Attr.class "button" ] [ emoji "👋" ]
                                ]
                            ]
                    )
             )
                ++ [ addUserInput model ]
            )
        ]


newIntervalFields : Model -> Html Msg
newIntervalFields model =
    let
        ( hoursOptions, minutesOptions, secondsOptions ) =
            MobSession.newIntervalOptions model.intervalSeconds

        optionsFormatter =
            List.map
                (\( val, selected ) -> option [ Attr.value val, Attr.selected selected ] [ text val ])
    in
    div [ Attr.class "interval-input" ]
        [ text "/"
        , space
        , select
            [ Attr.class "value-select"
            , onInput (UpdateInterval MobSession.Hour)
            , Attr.disabled model.mobbing
            ]
            (hoursOptions |> optionsFormatter)
        , text ":"
        , select
            [ Attr.class "value-select"
            , onInput (UpdateInterval MobSession.Min)
            , Attr.disabled model.mobbing
            ]
            (minutesOptions |> optionsFormatter)
        , text ":"
        , select
            [ Attr.class "value-select"
            , onInput (UpdateInterval MobSession.Sec)
            , Attr.disabled model.mobbing
            ]
            (secondsOptions |> optionsFormatter)
        ]


emoji : String -> Html msg
emoji str =
    span [ Attr.class "standardized-emoji" ] [ text str ]


satisfiedMinMembers : Model -> Bool
satisfiedMinMembers model =
    List.length model.users >= 2


isReadyMobbing : Model -> Bool
isReadyMobbing model =
    satisfiedMinMembers model && (model.intervalSeconds > 0)


timerPanel : Model -> Html Msg
timerPanel model =
    div [ Attr.class "timer-panel" ]
        [ button
            [ Attr.title
                (if model.mobbing then
                    "Pause"

                 else
                    "Start"
                )
            , Attr.class "button major"
            , Attr.disabled (not (isReadyMobbing model))
            , onClick (UpdateMobbing (not model.mobbing))
            ]
            [ emoji "⏯️" ]
        , button
            [ Attr.title "Shuffle"
            , Attr.class "button major"
            , Attr.disabled (model.mobbing || not (satisfiedMinMembers model))
            , onClick ShuffleUsers
            ]
            [ emoji "🔀" ]
        , button
            [ Attr.title "Reset", Attr.class "button major", onClick ResetTimer ]
            [ emoji "↩️" ]
        , div
            [ Attr.title
                (if model.enabledSound then
                    "Mute"

                 else
                    "Enable sound"
                )
            , Attr.class "feature-toggle sound-toggle"
            ]
            [ input
                [ Attr.type_ "checkbox"
                , Attr.id "sound-toggle"
                , Attr.checked model.enabledSound
                , onCheck UpdateSoundMode
                ]
                []
            , label [ Attr.for "sound-toggle" ] []
            ]
        , div
            [ Attr.title
                (if model.enabledNotification then
                    "Disable notifications"

                 else
                    "Enable notification (if you approve)"
                )
            , Attr.class "feature-toggle notification-toggle"
            ]
            [ input
                [ Attr.type_ "checkbox"
                , Attr.id "notification-toggle"
                , Attr.checked model.enabledNotification
                , onCheck UpdateNotificationMode
                ]
                []
            , label [ Attr.for "notification-toggle" ] []
            ]
        , br [] []
        , div [ Attr.class "timer-row" ]
            [ emoji "⏲️"
            , space
            , text (MobSession.readableElapsed (Duration.elapsedSecondsFromDurations model.durations))
            ]
        , newIntervalFields model
        ]


space : Html msg
space =
    span [ Attr.class "chars-space" ] []


appHeader : Html msg
appHeader =
    header [ Attr.class "header" ]
        [ text "emobu"
        , a [ Attr.href "https://github.com/mobu-of-the-world/emobu/" ] [ img [ Attr.class "github-logo", Attr.src "/images/github-mark.svg" ] [] ]
        ]


appFooter : Model -> Html msg
appFooter model =
    footer [ Attr.class "footer" ]
        [ div [ Attr.class "footer-body" ]
            [ text "rev - "
            , a
                [ Attr.class "revision-link"
                , Attr.href ("https://github.com/mobu-of-the-world/emobu/tree/" ++ model.gitRef)
                ]
                [ text model.gitRef ]
            ]
        ]


view : Model -> Html Msg
view model =
    div [ Attr.id "page" ]
        [ appHeader
        , userPanel model
        , timerPanel model
        , appFooter model
        ]


onError : msg -> Attribute msg
onError msg =
    Html.Events.on "error" (Json.Decode.succeed msg)


getGithubAvatarUrl : String -> String
getGithubAvatarUrl username =
    "https://github.com/" ++ username ++ ".png"


subscriptions : Model -> Sub Msg
subscriptions model =
    if model.mobbing then
        -- Should be less than 1 sec. No actual interval. Ref: https://github.com/mobu-of-the-world/mobu/pull/486
        Time.every 500 Tick

    else
        Sub.none
