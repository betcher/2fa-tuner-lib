#!/bin/bash

function token_present ()
{
	cnt=`lsusb | grep "0a89:0030" | wc -l`
	if [[ cnt -eq 0 ]]
		then echoerr "Устройство семейства Рутокен ЭЦП не найдено"
		return 1
	fi

	return 0
}

function check_pin()
{
	token=$1
	pin=$2
	out=`pkcs11-tool --module "$LIBRTPKCS11ECP" -l -p "$pin" --show-info --slot-description "$token" 2>&1`
	res=$?
	out=`echo -e "$out" | grep "CKR_PIN_LOCKED"`
	if ! [[ -z "$out" ]]
	then
		return 2
	fi	
	return $res
}

function check_admin_pin()
{
        token=$1
        pin=$2
        out=`pkcs11-tool --module "$LIBRTPKCS11ECP" -l --so-pin "$pin" --login-type so --show-info --slot-description "$token" 2>&1`
        res=$?
        out=`echo -e "$out" | grep "CKR_PIN_LOCKED"`
        if ! [[ -z "$out" ]]
        then
                return 2
        fi
        return $res
}

function get_cert_list ()
{
	cert_ids=`pkcs11-tool --module $LIBRTPKCS11ECP -O --type cert 2> /dev/null | grep -Eo "ID:.*" |  awk '{print $2}'`;
	echo "$cert_ids";
	return 0
}

function import_obj_on_token ()
{
	token=$1
	type=$2
	path_to_obj=$3
	label=$4
	key_id=$5
	
	pkcs11-tool --module "$LIBRTPKCS11ECP" -l -p "$PIN" -y "$type" -w "$path_to_obj" --id "$key_id" --label "$label" --slot-description "$token" > /dev/null 2> /dev/null;
	if [[ $? -ne 0 ]]
	then
		echoerr "Не удалось импортировать объкт на Рутокен"
		return 1
	fi

	return 0
}

function get_key_list ()
{
        key_ids=`pkcs11-tool --module $LIBRTPKCS11ECP -O --type pubkey --slot-description "$token" 2> /dev/null | grep -Eo "ID:.*" |  awk '{print $2}'`;
        echo "$key_ids";
	return 0
}

function get_cert_list ()
{
        cert_ids=`pkcs11-tool --module $LIBRTPKCS11ECP -O --type cert  --slot-description "$token" 2> /dev/null | grep -Eo "ID:.*" |  awk '{print $2}'`;
        echo "$cert_ids";
	return 0
}

function pkcs11_gen_key ()
{
	token=$1
        key_id=$2
	type=$3
	label=$4

	out=`pkcs11-tool --module "$LIBRTPKCS11ECP" --keypairgen --key-type "$type" -l -p "$PIN" --id "$key_id" --label "$label" --slot-description "$token" 2>&1`
	if [[ "`echo -e "$out" | grep "Unknown key type"`" ]]
	then
		echoerr "Тип ключа $type не поддерживается в системе"
		return 2
	fi
	return $?
}

function pkcs11_create_cert_req ()
{
	token="$1"
	key_id="$2"
	subj="$3"
	req_path="$4"
	choice="$5"
	key_id_ascii="`echo -e "$key_id" | sed 's/../%&/g'`"
	
	obj=`get_token_objects "$token" "privkey" "id" "$key_id"`
	type=`get_object_attribute_value "$obj" "type"`
	if [[ "$type" == "RSA"* ]]
	then
		engine_path="$PKCS11_ENGINE"
		engine_id=pkcs11
	else
		engine_path="$RTENGINE"
		engine_id=rtengine
	fi

	serial=`get_token_info "$token" "serial"`

        openssl_req="engine dynamic -pre SO_PATH:"$engine_path" -pre ID:"$engine_id" -pre LIST_ADD:1  -pre LOAD -pre MODULE_PATH:$LIBRTPKCS11ECP \n req -engine $engine_id -new -utf8 -key \"pkcs11:serial=$serial;id=$key_id_ascii\" -keyform engine -passin \"pass:$PIN\" -subj $subj"
	
	if [[ choice -eq 1  ]]
        then
                out=`echo -e "$openssl_req -x509 -outform DER -out \"$req_path\"" | openssl 2>&1`;

                if [[ $? -ne 0 ]]
		then
			echoerr "Не удалось создать сертификат"
			return 1
		fi
		pkcs11-tool --module $LIBRTPKCS11ECP -l -p "$PIN" -y cert -w "$req_path" --id $key_id > /dev/null 2> /dev/null;
        	if [[ $? -ne 0 ]]
                then
                        echoerr "Не удалось загрузить сертификат на токен"
                        return 1
                fi
	else
                out=`echo -e "$openssl_req -out \"$req_path\" -outform PEM" | openssl 2>&1`;
                if [[ "`echo -e "$out" | grep "error"`" ]]
		then
			echoerr "Не удалось создать заявку на сертификат"
			return 1
		fi
        fi

	return 0
}

function get_token_list () 
{
	echo -e "`pkcs11-tool --module $LIBRTPKCS11ECP -T 2> /dev/null | grep "Slot *" | cut -d ":" -f2- | awk '$1=$1'`"
	return 0
}

function get_token_info ()
{
	token=$1
	atr=$2

        token_info=`pkcs11-tool --module $LIBRTPKCS11ECP -T | sed -n "/^.*$token.*$/ { :a; n; p; ba; }" | awk '{$1=$1;print}' | sed -E "s/[[:space:]]*:[[:space:]]+/\t/" | uniq | awk '/Slot /{++n} n<2'`
        if [[ "$atr" ]]
	then
		echo -e "$token_info" | grep "$atr" | cut -f 2
		return 0
	fi
	
	echo -e "$token_info"
	return 0
}

function get_token_objects ()
{
	token="$1"
	type="$2"
	attr="$3"
	val="$4"
	if [[ "$type" ]]
	then
		type_arg="--type $type"
	fi

	objs=`pkcs11-tool --module $LIBRTPKCS11ECP -O -l -p "$PIN" $type_arg --slot-description "$token"`
	if [[ "$attr" ]]
	then
		objs=`python3 "$TWO_FA_LIB_DIR/python_utils/parse_objects.py" "$objs" "$type" "$attr" "$val"`
	else
		objs=`python3 "$TWO_FA_LIB_DIR/python_utils/parse_objects.py" "$objs"`
	fi
        
	echo -e "$objs"
	return 0
}

function get_object_attribute_value ()
{
	obj=$1
	attr=$2
	echo -e "$obj" | python3 -c "import json,sys; obj=json.load(sys.stdin); print(obj[\"$attr\"])"
	return $?
}

function pkcs11_format_token ()
{
	local token="$1"
	local user_pin="$2"
	local admin_pin="$3"
	PIN=$user_pin
	
	list=`get_token_list`		
	if  [[ "`echo -e "$list" | wc -l`" -ne 1 ]] 
	then
		echoerr "Вставленно более одного токена"
		return 2
	fi

	$RTADMIN -z "$LIBRTPKCS11ECP" -f -u "$user_pin" -a "$admin_pin" -q
	return $?
}

function pkcs11_change_user_pin ()
{
	token=$1
	old_pin=$PIN
	new_pin=$2
	PIN=$new_pin
	pkcs11-tool --module "$LIBRTPKCS11ECP" --change-pin -l -p "$old_pin" --new-pin "$new_pin" --slot-description "$token"
	return $?
}

function pkcs11_change_admin_pin ()
{
	local token=$1
	local old_pin=$2
	local new_pin=$3
	pkcs11-tool --module "$LIBRTPKCS11ECP" -c --login-type so --so-pin "$old_pin" -l --new-pin "$new_pin"
	return $?
}

function pkcs11_unlock_pin ()
{
	local token=$1
	local so_pin=$2

	list=`get_token_list`
        if  [[ "`echo -e "$list" | wc -l`" -ne 1 ]]
        then
                echoerr "Вставленно более одного токена"
                return 2
        fi
	
	$RTADMIN -z "$LIBRTPKCS11ECP" -q -P -o "$so_pin"
	return $?
}

function export_object ()
{
	local token=$1
	local type=$2
	local id=$3
	local file=$4
	pkcs11-tool --module "$LIBRTPKCS11ECP" --slot-description "$token" -r --type "$type" --id "$id" -l -p "$PIN" > "$file"
	return $?
}

function remove_object ()
{
        local token=$1
        local type=$2
        local id=$3
        pkcs11-tool --module "$LIBRTPKCS11ECP" --slot-description "$token" -b --type "$type" --id "$id" -l -p "$PIN"
        return $?
}

