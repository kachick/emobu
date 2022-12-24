module Model exposing (DecodedModel, IntervalUnit(..), Model, User, decoder, defaultValues, encode)

import Json.Decode
import Json.Encode


type alias User =
    { username : String
    , avatarUrl : String
    }


type IntervalUnit
    = Min
    | Sec


type alias Model =
    { inputtedUsername : String
    , users : List User
    , elapsedSeconds : Int
    , intervalSeconds : Int
    , inputtedInterval : String
    , mobbing : Bool
    , debugMode : Bool
    , enabledSound : Bool
    , commitRef : String
    , intervalUnit : IntervalUnit
    }


type alias DecodedModel =
    { users : List User, commitRef : Maybe String, enabledSound : Maybe Bool }


defaultIntervalMinutes : Int
defaultIntervalMinutes =
    30


defaultValues : Model
defaultValues =
    { users = []
    , inputtedUsername = ""
    , elapsedSeconds = 0
    , intervalSeconds = defaultIntervalMinutes * 60
    , inputtedInterval = String.fromInt defaultIntervalMinutes
    , mobbing = False
    , debugMode = False
    , enabledSound = True
    , commitRef = "unknown ref"
    , intervalUnit = Min
    }


userEncoder : User -> Json.Encode.Value
userEncoder user =
    Json.Encode.object [ ( "username", Json.Encode.string user.username ), ( "avatarUrl", Json.Encode.string user.avatarUrl ) ]


encode : Model -> Json.Encode.Value
encode model =
    Json.Encode.object
        [ ( "users", Json.Encode.list userEncoder model.users )
        , ( "enabledSound", Json.Encode.bool model.enabledSound )
        ]


userDecoder : Json.Decode.Decoder User
userDecoder =
    Json.Decode.map2 User
        (Json.Decode.field "username" Json.Decode.string)
        (Json.Decode.field "avatarUrl" Json.Decode.string)


decoder : Json.Decode.Decoder DecodedModel
decoder =
    Json.Decode.map3 DecodedModel
        (Json.Decode.field "users" (Json.Decode.list userDecoder))
        (Json.Decode.maybe (Json.Decode.field "commitRef" Json.Decode.string))
        (Json.Decode.maybe (Json.Decode.field "enabledSound" Json.Decode.bool))
